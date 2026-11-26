import Foundation
import Testing

@testable import AppCore

// MARK: - Helpers

private func makeStore() throws -> (JobStore, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("JobQueueTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (JobStore(directory: dir), dir)
}

private func makeJob(tool: String = "fake", name: String = "a") -> Job {
    Job(
        toolID: tool, source: URL(fileURLWithPath: "/tmp/\(name).mov"),
        sourceBookmark: Data(), settings: Data())
}

private struct Boom: LocalizedError {
    var errorDescription: String? { "boom happened" }
}

private struct Plain: Error {}

private func completed(_ name: String = "out") -> JobState {
    .completed(
        JobOutcome(
            output: URL(fileURLWithPath: "/tmp/\(name).mov"), bytesBefore: 10, bytesAfter: 5,
            report: MetadataReport(), replacedOriginal: false))
}

/// A runner whose jobs finish only when the test says so. No timing involved.
private actor ScriptedRunner: JobRunner {
    private var log: [String] = []
    private var active = 0
    private(set) var maxActive = 0
    private var pending: [UUID: CheckedContinuation<JobState, any Error>] = [:]
    private var early: [UUID: Result<JobState, any Error>] = [:]
    private let startedContinuation: AsyncStream<UUID>.Continuation
    nonisolated let started: AsyncStream<UUID>

    init() {
        (started, startedContinuation) = AsyncStream.makeStream(of: UUID.self)
    }

    var events: [String] { log }

    func run(_ job: Job, progress: @escaping @Sendable (Double) -> Void) async throws -> JobState {
        log.append("start \(job.source.deletingPathExtension().lastPathComponent)")
        active += 1
        maxActive = max(maxActive, active)
        startedContinuation.yield(job.id)
        defer { active -= 1 }
        do {
            let state: JobState = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if let result = early.removeValue(forKey: job.id) {
                        continuation.resume(with: result)
                    } else {
                        pending[job.id] = continuation
                    }
                }
            } onCancel: {
                Task { await self.finish(job.id, .failure(CancellationError())) }
            }
            log.append("end \(job.source.deletingPathExtension().lastPathComponent)")
            return state
        } catch {
            log.append("abort \(job.source.deletingPathExtension().lastPathComponent)")
            throw error
        }
    }

    func finish(_ id: UUID, _ result: Result<JobState, any Error>) {
        if let continuation = pending.removeValue(forKey: id) {
            continuation.resume(with: result)
        } else {
            early[id] = result
        }
    }
}

/// Reads the queue's update stream until `predicate` holds.
private func waitUntil(
    _ queue: JobQueue, _ predicate: @Sendable ([Job]) -> Bool
) async {
    for await jobs in await queue.updates() where predicate(jobs) { return }
}

// MARK: - Tests

@Test func runsSeriallyInOrder() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = ScriptedRunner()
    let queue = JobQueue(store: store, runners: ["fake": runner])
    let jobs = ["a", "b", "c"].map { makeJob(name: $0) }
    var starts = runner.started.makeAsyncIterator()

    await queue.enqueue(jobs)
    for job in jobs {
        let startedID = await starts.next()
        #expect(startedID == job.id)
        await runner.finish(job.id, .success(completed()))
    }
    await waitUntil(queue) { $0.allSatisfy { if case .completed = $0.state { true } else { false } } }

    #expect(
        await runner.events == ["start a", "end a", "start b", "end b", "start c", "end c"])
    #expect(await runner.maxActive == 1)
}

@Test func pauseFinishesCurrent() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = ScriptedRunner()
    let queue = JobQueue(store: store, runners: ["fake": runner])
    let first = makeJob(name: "a")
    let second = makeJob(name: "b")
    var starts = runner.started.makeAsyncIterator()

    await queue.enqueue([first, second])
    _ = await starts.next()
    await queue.pause()
    #expect(await queue.isPaused())
    await runner.finish(first.id, .success(completed()))
    await waitUntil(queue) { jobs in
        if case .completed = jobs[0].state { return true } else { return false }
    }

    let snapshot = await queue.jobs
    #expect(snapshot[1].state == .queued)
    #expect(await runner.events == ["start a", "end a"])

    await queue.resume()
    #expect(await queue.isPaused() == false)
    let startedID = await starts.next()
    #expect(startedID == second.id)
    await runner.finish(second.id, .success(completed()))
    await waitUntil(queue) { $0.allSatisfy { if case .completed = $0.state { true } else { false } } }
}

@Test func failureBecomesFailedWithReason() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = ScriptedRunner()
    let queue = JobQueue(store: store, runners: ["fake": runner])
    let localized = makeJob(name: "a")
    let plain = makeJob(name: "b")
    var starts = runner.started.makeAsyncIterator()

    await queue.enqueue([localized, plain])
    _ = await starts.next()
    await runner.finish(localized.id, .failure(Boom()))
    _ = await starts.next()
    await runner.finish(plain.id, .failure(Plain()))
    await waitUntil(queue) { $0.allSatisfy { if case .failed = $0.state { true } else { false } } }

    let jobs = await queue.jobs
    #expect(jobs[0].state == .failed(reason: "boom happened", code: .conversionFailed))
    #expect(jobs[1].state == .failed(reason: "The video couldn't be converted.", code: .conversionFailed))
}

/// A Cocoa error reads as its sentence, not as a dump of its domain, code and user info.
@Test func cocoaErrorFailsWithItsLocalizedDescription() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = ScriptedRunner()
    let queue = JobQueue(store: store, runners: ["fake": runner])
    let job = makeJob(name: "sdr-4k")
    var starts = runner.started.makeAsyncIterator()
    let error = CocoaError(
        .fileReadNoPermission,
        userInfo: [NSFilePathErrorKey: "/tmp/sdr-4k.mov", "AVAssetPropertyKeys": ["duration", "tracks"]])

    await queue.enqueue([job])
    _ = await starts.next()
    await runner.finish(job.id, .failure(error))
    await waitUntil(queue) { if case .failed = $0.first?.state { true } else { false } }

    guard case .failed(let reason, _) = await queue.jobs.first?.state else {
        Issue.record("expected failed")
        return
    }
    #expect(reason == error.localizedDescription)
    #expect(reason.contains("sdr-4k.mov"))
    #expect(!reason.contains("Domain"))
    #expect(!reason.contains("AVAssetPropertyKeys"))
}

@Test func unknownToolFails() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let queue = JobQueue(store: store, runners: [:])
    await queue.enqueue([makeJob(tool: "nope")])
    await waitUntil(queue) { $0.first?.state == .failed(reason: "No tool can run this job", code: .noToolForJob) }
}

@Test func retryRequeues() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = ScriptedRunner()
    let queue = JobQueue(store: store, runners: ["fake": runner])
    let job = makeJob()
    var starts = runner.started.makeAsyncIterator()

    await queue.enqueue([job])
    _ = await starts.next()
    await runner.finish(job.id, .failure(Boom()))
    await waitUntil(queue) { $0.first?.state == .failed(reason: "boom happened", code: .conversionFailed) }

    await queue.retry(job.id)
    _ = await starts.next()
    await runner.finish(job.id, .success(completed()))
    await waitUntil(queue) { jobs in
        if case .completed = jobs[0].state { return true } else { return false }
    }
}

@Test func retryOnlyAppliesToFailedAndRetryAllFailedRequeuesEach() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let queue = JobQueue(store: store, runners: [:])
    let a = makeJob(tool: "nope", name: "a")
    let b = makeJob(tool: "nope", name: "b")
    await queue.pause()
    await queue.enqueue([a, b])
    await queue.retry(a.id)  // queued, not failed: no-op
    #expect(await queue.jobs.map(\.state) == [.queued, .queued])

    await queue.resume()
    await waitUntil(queue) {
        $0.allSatisfy { $0.state == .failed(reason: "No tool can run this job", code: .noToolForJob) }
    }
    await queue.pause()
    await queue.retryAllFailed()
    #expect(await queue.jobs.map(\.state) == [.queued, .queued])
}

@Test func removeSkipsRunningJobs() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = ScriptedRunner()
    let queue = JobQueue(store: store, runners: ["fake": runner])
    let running = makeJob(name: "a")
    let waiting = makeJob(name: "b")
    var starts = runner.started.makeAsyncIterator()

    await queue.enqueue([running, waiting])
    _ = await starts.next()
    await queue.remove(running.id)
    #expect(await queue.jobs.count == 2)
    await queue.remove(waiting.id)
    #expect(await queue.jobs.map(\.id) == [running.id])

    await runner.finish(running.id, .success(completed()))
    await queue.shutdown()
}

@Test func runningJobRecoveredAsQueued() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    var stuck = makeJob()
    stuck.state = .running(progress: 0.4)
    try store.save([stuck])

    let queue = JobQueue(store: store, runners: [:])
    #expect(await queue.jobs.map(\.state) == [.queued])
    #expect(store.load().map(\.state) == [.queued])
}

@Test func jobsPersistAcrossQueues() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let queue = JobQueue(store: store, runners: [:])
    await queue.pause()
    let job = makeJob()
    await queue.enqueue([job])

    let reopened = JobQueue(store: store, runners: [:])
    #expect(await reopened.jobs == [job])
}

@Test func shutdownCancelsRunningJobAndRequeuesIt() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = ScriptedRunner()
    let queue = JobQueue(store: store, runners: ["fake": runner])
    let job = makeJob()
    var starts = runner.started.makeAsyncIterator()

    await queue.enqueue([job])
    _ = await starts.next()
    await queue.shutdown()

    #expect(await queue.jobs.map(\.state) == [.queued])
    #expect(store.load().map(\.state) == [.queued])
    #expect(await runner.events.last == "abort a")
}

@Test func updatesYieldCurrentThenChangesToEverySubscriber() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let queue = JobQueue(store: store, runners: [:])
    await queue.pause()
    var one = await queue.updates().makeAsyncIterator()
    var two = await queue.updates().makeAsyncIterator()
    #expect(await one.next() == [])
    #expect(await two.next() == [])

    let job = makeJob()
    await queue.enqueue([job])
    #expect(await one.next() == [job])
    #expect(await two.next() == [job])

    await queue.shutdown()
    #expect(await one.next() == nil)
    #expect(await two.next() == nil)
}

@Test func progressIsReportedWhileRunning() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let reporter = ProgressRunner()
    let queue = JobQueue(store: store, runners: ["fake": reporter])
    await queue.enqueue([makeJob()])
    await waitUntil(queue) { $0.first?.state == .running(progress: 0.5) }
    await reporter.release()
    await queue.shutdown()
}

private actor ProgressRunner: JobRunner {
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false

    func run(_ job: Job, progress: @escaping @Sendable (Double) -> Void) async throws -> JobState {
        progress(0.5)
        if !released { await withCheckedContinuation { gate = $0 } }
        return .keptAsIs(reason: "done")
    }

    func release() {
        released = true
        gate?.resume()
        gate = nil
    }
}

@Test func cancellationErrorWithoutShutdownFailsTheJob() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = ScriptedRunner()
    let queue = JobQueue(store: store, runners: ["fake": runner])
    let job = makeJob()
    var starts = runner.started.makeAsyncIterator()

    await queue.enqueue([job])
    _ = await starts.next()
    await runner.finish(job.id, .failure(CancellationError()))
    await waitUntil(queue) { jobs in
        if case .failed = jobs[0].state { return true } else { return false }
    }
    #expect(await runner.events == ["start a", "abort a"])
    await queue.shutdown()
}

@Test func recoveredJobRunsAfterResume() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    var stuck = makeJob()
    stuck.state = .running(progress: 0.4)
    try store.save([stuck])
    let runner = ScriptedRunner()
    let queue = JobQueue(store: store, runners: ["fake": runner])
    var starts = runner.started.makeAsyncIterator()

    await queue.resume()
    let startedID = await starts.next()
    #expect(startedID == stuck.id)
    await runner.finish(stuck.id, .success(completed()))
    await waitUntil(queue) { jobs in
        if case .completed = jobs[0].state { return true } else { return false }
    }
}

@Test func retryDoesNotDuplicatePendingFile() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let queue = JobQueue(store: store, runners: [:])
    let failedA = makeJob(tool: "nope", name: "a")
    let failedC1 = makeJob(tool: "nope", name: "c")
    await queue.enqueue([failedA])
    await waitUntil(queue) { $0.allSatisfy { if case .failed = $0.state { true } else { false } } }
    await queue.pause()
    // A second failed job for the same file "c": possible since finished jobs don't block re-adding.
    await queue.enqueue([failedC1])
    await queue.resume()
    await waitUntil(queue) { $0.allSatisfy { if case .failed = $0.state { true } else { false } } }
    let failedC2 = makeJob(tool: "nope", name: "c")
    await queue.enqueue([failedC2])
    await waitUntil(queue) { $0.count == 3 && $0.allSatisfy { if case .failed = $0.state { true } else { false } } }
    await queue.pause()

    // The user re-adds "a" while its old job is failed; retrying the old job must not queue the file twice.
    let readded = makeJob(tool: "nope", name: "a")
    #expect(await queue.enqueue([readded]).map(\.id) == [readded.id])
    await queue.retry(failedA.id)
    func state(_ id: UUID) async -> JobState? { await queue.jobs.first { $0.id == id }?.state }
    #expect(await state(failedA.id) == .failed(reason: "No tool can run this job", code: .noToolForJob))

    // Retry all: "a" is still pending through the re-added job, and only one of the two "c" jobs goes back.
    await queue.retryAllFailed()
    #expect(await state(failedA.id) == .failed(reason: "No tool can run this job", code: .noToolForJob))
    #expect(await state(failedC1.id) == .queued)
    #expect(await state(failedC2.id) == .failed(reason: "No tool can run this job", code: .noToolForJob))
    #expect(await state(readded.id) == .queued)
    await queue.shutdown()
}

@Test func queueStartedPausedRunsNothingUntilResume() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = ScriptedRunner()
    let queue = JobQueue(store: store, runners: ["fake": runner], startPaused: true)
    #expect(await queue.isPaused())
    let job = makeJob()
    var starts = runner.started.makeAsyncIterator()

    await queue.enqueue([job])
    await queue.retryAllFailed()
    #expect(await queue.jobs.map(\.state) == [.queued])
    #expect(await runner.events.isEmpty)

    await queue.resume()
    #expect(await starts.next() == job.id)
    await runner.finish(job.id, .success(completed()))
    await waitUntil(queue) { jobs in
        if case .completed = jobs[0].state { return true } else { return false }
    }
}

// MARK: - Cancel

@Test func cancellingTheRunningJobRemovesItAndRunsTheNext() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = ScriptedRunner()
    let queue = JobQueue(store: store, runners: ["fake": runner])
    let (a, b) = (makeJob(name: "a"), makeJob(name: "b"))
    var starts = runner.started.makeAsyncIterator()

    await queue.enqueue([a, b])
    _ = await starts.next()
    await queue.cancel(a.id)
    #expect(await starts.next() == b.id)

    #expect(await queue.jobs.map(\.id) == [b.id])
    #expect(store.load().map(\.id) == [b.id])
    #expect(await runner.events == ["start a", "abort a", "start b"])
    await queue.shutdown()
}

@Test func cancellingAQueuedJobRemovesIt() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let queue = JobQueue(store: store, runners: [:], startPaused: true)
    let (a, b) = (makeJob(name: "a"), makeJob(name: "b"))
    await queue.enqueue([a, b])

    await queue.cancel(b.id)

    #expect(await queue.jobs.map(\.id) == [a.id])
}

@Test func cancelIgnoresFinishedJobs() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    var done = makeJob()
    done.state = .failed(reason: "boom")
    try store.save([done])
    let queue = JobQueue(store: store, runners: [:])

    await queue.cancel(done.id)
    await queue.cancelAll()

    #expect(await queue.jobs == [done])
}

@Test func cancelAllRemovesQueuedJobsAndCancelsTheRunningOne() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = ScriptedRunner()
    var finished = makeJob(name: "done")
    finished.state = .completed(
        JobOutcome(
            output: URL(fileURLWithPath: "/tmp/done (1080p).mov"), bytesBefore: 10, bytesAfter: 5,
            report: MetadataReport(), replacedOriginal: false))
    try store.save([finished])
    let restored = JobQueue(store: store, runners: ["fake": runner])
    let jobs = ["a", "b", "c"].map { makeJob(name: $0) }
    var starts = runner.started.makeAsyncIterator()

    await restored.enqueue(jobs)
    _ = await starts.next()
    await restored.cancelAll()
    await waitUntil(restored) { $0.count == 1 }

    #expect(await restored.jobs.map(\.id) == [finished.id])
    #expect(await runner.events == ["start a", "abort a"])
    #expect(store.load().map(\.id) == [finished.id])
    await restored.shutdown()
}

@Test func aJobThatFinishesAsItIsCancelledKeepsItsResult() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = ScriptedRunner()
    let queue = JobQueue(store: store, runners: ["fake": runner])
    let job = makeJob()
    var starts = runner.started.makeAsyncIterator()

    await queue.enqueue([job])
    _ = await starts.next()
    // The result arrives before the cancellation reaches the runner: it stands (a Replace may already be done).
    await runner.finish(job.id, .success(completed()))
    await queue.cancel(job.id)
    await waitUntil(queue) { !$0.isEmpty && !$0[0].state.isPending }

    #expect(await queue.jobs.map(\.state) == [completed()])
    await queue.shutdown()
}

// MARK: - Store

@Test func unreadableJobsFileIsSetAsideAndReported() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let garbage = Data("{ not jobs".utf8)
    try garbage.write(to: dir.appendingPathComponent("jobs.json"))

    let queue = JobQueue(store: store, runners: [:])

    #expect(await queue.jobs.isEmpty)
    let error = try #require(await queue.loadError)
    #expect(error.contains("jobs.json.corrupt-"))
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    let aside = try #require(names.first { $0.hasPrefix("jobs.json.corrupt-") })
    #expect(try Data(contentsOf: dir.appendingPathComponent(aside)) == garbage)
    #expect(!names.contains("jobs.json"))
    // The next save starts a fresh file and leaves the set-aside one alone.
    await queue.enqueue([makeJob()])
    #expect(try Data(contentsOf: dir.appendingPathComponent(aside)) == garbage)
}

@Test func readableOrMissingJobsFileReportsNoError() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(await JobQueue(store: store, runners: [:]).loadError == nil)
    try store.save([makeJob()])
    #expect(await JobQueue(store: store, runners: [:]).loadError == nil)
}

@Test func jobsFileThatCantBeReadIsNeverSavedOver() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    try store.save([makeJob(name: "saved")])
    let file = dir.appendingPathComponent("jobs.json")
    let saved = try Data(contentsOf: file)
    // Exists but can't be read (permissions here; a failing disk in real life).
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }

    let queue = JobQueue(store: store, runners: [:], startPaused: true)

    let error = try #require(await queue.loadError)
    #expect(error.contains("won't be saved"))
    await queue.enqueue([makeJob(name: "new")])
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    #expect(try Data(contentsOf: file) == saved)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["jobs.json"])
}

@Test func jobsFileThatCantBeSetAsideIsNeverSavedOver() async throws {
    let (_, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let garbage = Data("{ not jobs".utf8)
    let file = dir.appendingPathComponent("jobs.json")
    try garbage.write(to: file)
    var store = JobStore(directory: dir)
    store.moveItem = { _, _ in throw CocoaError(.fileWriteNoPermission) }

    let queue = JobQueue(store: store, runners: [:], startPaused: true)

    let error = try #require(await queue.loadError)
    #expect(error.contains("won't be saved"))
    await queue.enqueue([makeJob()])
    #expect(try Data(contentsOf: file) == garbage)
}

// MARK: - Progress throttling

/// Reports `count` progress values as fast as it can (the last is 1), then waits until released.
private actor FloodRunner: JobRunner {
    private let count: Int
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false
    private let floodedContinuation: AsyncStream<Void>.Continuation
    /// Yields once every progress value has been reported.
    nonisolated let flooded: AsyncStream<Void>

    init(count: Int) {
        self.count = count
        (flooded, floodedContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    func run(_ job: Job, progress: @escaping @Sendable (Double) -> Void) async throws -> JobState {
        for step in 1...count { progress(Double(step) / Double(count)) }
        floodedContinuation.yield()
        if !released { await withCheckedContinuation { gate = $0 } }
        return .keptAsIs(reason: "done")
    }

    func release() {
        released = true
        gate?.resume()
        gate = nil
    }
}

@Test(.timeLimit(.minutes(1))) func progressIsPublishedAtMostTenTimesASecondAndEndsOnTheLastValue() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = FloodRunner(count: 2000)
    let queue = JobQueue(store: store, runners: ["fake": runner])
    let start = ContinuousClock.now
    let updates = await queue.updates()
    let counter = Task {
        var progressUpdates = 0
        for await jobs in updates {
            guard case .running(let progress) = jobs.first?.state, progress > 0 else { continue }
            progressUpdates += 1
            if progress == 1 { return progressUpdates }
        }
        return progressUpdates
    }

    await queue.enqueue([makeJob()])
    let progressUpdates = await counter.value
    let elapsed = start.duration(to: .now)

    // One right away, then at most one per 100 ms; the last value still arrives.
    #expect(progressUpdates <= Int(elapsed / .milliseconds(100)) + 2)
    await runner.release()
    await queue.shutdown()
}

@Test(.timeLimit(.minutes(1))) func stateChangesArePublishedAtOnceWhateverTheProgressInterval() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = FloodRunner(count: 500)
    // Far longer than the test may take: only state changes can get through in time.
    let queue = JobQueue(store: store, runners: ["fake": runner], progressInterval: .seconds(3600))
    var flooded = runner.flooded.makeAsyncIterator()
    await queue.enqueue([makeJob()])
    await flooded.next()

    await runner.release()

    await waitUntil(queue) { $0.first?.state == .keptAsIs(reason: "done") }
    await queue.shutdown()
}

// MARK: - Automatic hold (a hot Mac, a low battery)

@Test func automaticHoldFinishesTheCurrentJobThenStartsNothing() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = ScriptedRunner()
    let queue = JobQueue(store: store, runners: ["fake": runner])
    let first = makeJob(name: "a")
    let second = makeJob(name: "b")
    var starts = runner.started.makeAsyncIterator()

    await queue.enqueue([first, second])
    _ = await starts.next()
    await queue.setAutomaticHold(true)
    #expect(await queue.isHeldAutomatically())
    #expect(await queue.isPaused() == false)
    await runner.finish(first.id, .success(completed()))
    await waitUntil(queue) { jobs in
        if case .completed = jobs[0].state { return true } else { return false }
    }

    #expect(await queue.jobs[1].state == .queued)
    #expect(await runner.events == ["start a", "end a"])

    await queue.setAutomaticHold(false)
    let startedID = await starts.next()
    #expect(startedID == second.id)
    await runner.finish(second.id, .success(completed()))
    await waitUntil(queue) { $0.allSatisfy { if case .completed = $0.state { true } else { false } } }
    await queue.shutdown()
}

@Test func resumeDoesNotLiftAnAutomaticHold() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = ScriptedRunner()
    let queue = JobQueue(store: store, runners: ["fake": runner])
    await queue.setAutomaticHold(true)

    await queue.enqueue([makeJob(name: "a")])
    await queue.resume()

    #expect(await queue.jobs.map(\.state) == [.queued])
    #expect(await runner.events.isEmpty)
    await queue.shutdown()
}

@Test func liftingTheAutomaticHoldNeverOverridesTheUsersPause() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = ScriptedRunner()
    let queue = JobQueue(store: store, runners: ["fake": runner])
    await queue.pause()
    await queue.setAutomaticHold(true)

    await queue.enqueue([makeJob(name: "a")])
    await queue.setAutomaticHold(false)

    #expect(await queue.isPaused())
    #expect(await queue.jobs.map(\.state) == [.queued])
    #expect(await runner.events.isEmpty)
    await queue.shutdown()
}

@Test func theUsersResumeStartsTheQueueOnceTheHoldIsLifted() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = ScriptedRunner()
    let queue = JobQueue(store: store, runners: ["fake": runner])
    let job = makeJob(name: "a")
    var starts = runner.started.makeAsyncIterator()
    await queue.pause()
    await queue.setAutomaticHold(true)
    await queue.enqueue([job])

    await queue.resume()
    #expect(await runner.events.isEmpty)
    await queue.setAutomaticHold(false)
    let startedID = await starts.next()
    #expect(startedID == job.id)
    await runner.finish(job.id, .success(completed()))
    await waitUntil(queue) { $0.allSatisfy { if case .completed = $0.state { true } else { false } } }
    await queue.shutdown()
}

// MARK: - Quitting while converting

@Test func quittingKeepsTheRunningJobAndTheRestOfTheQueueForNextLaunch() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = ScriptedRunner()
    let queue = JobQueue(store: store, runners: ["fake": runner])
    let jobs = ["a", "b", "c"].map { makeJob(name: $0) }
    var starts = runner.started.makeAsyncIterator()

    await queue.enqueue(jobs)
    _ = await starts.next()
    await queue.shutdown()

    // Saved as queued, in order, ready for the next launch.
    #expect(store.load().map(\.id) == jobs.map(\.id))
    #expect(store.load().map(\.state) == [.queued, .queued, .queued])
    let relaunched = JobQueue(store: store, runners: ["fake": ScriptedRunner()], startPaused: true)
    #expect(await relaunched.jobs.map(\.state) == [.queued, .queued, .queued])
    await relaunched.shutdown()
}
