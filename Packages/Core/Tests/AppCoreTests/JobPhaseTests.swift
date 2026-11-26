import Foundation
import Testing

@testable import AppCore

// Phases a runner reports, outcome updates after a run, and jobs whose source is not a file.

private func makeStore() throws -> (JobStore, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("JobPhaseTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (JobStore(directory: dir), dir)
}

private func makeJob(name: String = "a") -> Job {
    Job(
        toolID: "fake", source: URL(fileURLWithPath: "/tmp/\(name).mov"), sourceBookmark: Data(),
        settings: Data())
}

private func completed() -> JobState {
    .completed(
        JobOutcome(
            output: URL(fileURLWithPath: "/tmp/out.mov"), bytesBefore: 10, bytesAfter: 5,
            report: MetadataReport(), replacedOriginal: false))
}

private func waitUntil(_ queue: JobQueue, _ predicate: @Sendable ([Job]) -> Bool) async {
    for await jobs in await queue.updates() where predicate(jobs) { return }
}

/// Reports a phase and progress, waits for the test to open the gate, then finishes.
private actor PhasedRunner: JobRunner {
    private var gate: CheckedContinuation<Void, Never>?
    private var opened = false

    func open() {
        opened = true
        gate?.resume()
        gate = nil
    }

    func run(_ job: Job, progress: @escaping @Sendable (Double) -> Void) async throws -> JobState {
        try await run(job, progress: progress, phase: { _ in })
    }

    func run(
        _ job: Job, progress: @escaping @Sendable (Double) -> Void, phase: @escaping @Sendable (String?) -> Void
    ) async throws -> JobState {
        phase("Downloading from iCloud…")
        progress(0.5)
        await withCheckedContinuation { continuation in
            if opened { continuation.resume() } else { gate = continuation }
        }
        return completed()
    }
}

/// Finishes at once; a runner that doesn't know about phases.
private struct PlainRunner: JobRunner {
    func run(_ job: Job, progress: @escaping @Sendable (Double) -> Void) async throws -> JobState {
        progress(1)
        return completed()
    }
}

@Test func runnerPhaseIsPublishedWhileRunningAndClearedWhenDone() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = PhasedRunner()
    let queue = JobQueue(store: store, runners: ["fake": runner], progressInterval: .zero)
    await queue.enqueue([makeJob()])

    await waitUntil(queue) { jobs in
        guard let job = jobs.first, case .running(let progress) = job.state else { return false }
        return job.phase == "Downloading from iCloud…" && progress == 0.5
    }
    await runner.open()
    await waitUntil(queue) { jobs in
        guard let job = jobs.first, case .completed = job.state else { return false }
        return job.phase == nil
    }
}

@Test func aRunnerWithoutPhasesStillRuns() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let queue = JobQueue(store: store, runners: ["fake": PlainRunner()])
    await queue.enqueue([makeJob()])

    await waitUntil(queue) { jobs in
        guard let job = jobs.first, case .completed = job.state else { return false }
        return job.phase == nil
    }
}

@Test func aRestoredRunningJobComesBackQueuedWithoutAPhase() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    var job = makeJob()
    job.state = .running(progress: 0.4)
    job.phase = "Downloading from iCloud…"
    try store.save([job])

    let queue = JobQueue(store: store, runners: ["fake": PlainRunner()], startPaused: true)

    let restored = await queue.jobs
    #expect(restored.first?.state == .queued)
    #expect(restored.first?.phase == nil)
}

@Test func updateOutcomeChangesACompletedJobAndSavesIt() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let queue = JobQueue(store: store, runners: ["fake": PlainRunner()])
    let job = makeJob()
    await queue.enqueue([job])
    await waitUntil(queue) { jobs in
        if case .completed = jobs.first?.state { true } else { false }
    }

    await queue.updateOutcome(id: job.id) { $0.replacedOriginal = true }
    await queue.updateOutcome(id: UUID()) { $0.replacedOriginal = true }  // unknown id: ignored

    guard case .completed(let outcome) = await queue.jobs[0].state else {
        Issue.record("expected completed")
        return
    }
    #expect(outcome.replacedOriginal)
    guard case .completed(let saved) = store.load()[0].state else {
        Issue.record("expected the saved job to be completed")
        return
    }
    #expect(saved.replacedOriginal)
}

@Test func updateOutcomeLeavesAJobThatIsNotCompletedAlone() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let queue = JobQueue(store: store, runners: ["fake": PlainRunner()], startPaused: true)
    let job = makeJob()
    await queue.enqueue([job])

    await queue.updateOutcome(id: job.id) { $0.replacedOriginal = true }

    #expect(await queue.jobs[0].state == .queued)
}

@Test func updateQueuedEditsWaitingJobAndRefusesSourceCollision() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let queue = JobQueue(store: store, runners: ["fake": PlainRunner()], startPaused: true)
    let first = makeJob(name: "one")
    let second = makeJob(name: "two")
    await queue.enqueue([first, second])

    let updatedSettings = Data("updated".utf8)
    let ok = await queue.updateQueued(id: first.id) {
        $0.settings = updatedSettings
    }
    #expect(ok)
    #expect(await queue.jobs.first { $0.id == first.id }?.settings == updatedSettings)
    #expect(store.load().first { $0.id == first.id }?.settings == updatedSettings)

    // Swapping to another pending job's source is refused so the queue stays duplicate-free.
    let collides = await queue.updateQueued(id: first.id) {
        $0.source = second.source
    }
    #expect(!collides)
    #expect(await queue.jobs.first { $0.id == first.id }?.source == first.source)

    // Swapping to an unused video succeeds.
    let newURL = URL(filePath: "/tmp/three.mov")
    let swapped = await queue.updateQueued(id: first.id) {
        $0.source = newURL
    }
    #expect(swapped)
    #expect(await queue.jobs.first { $0.id == first.id }?.source == newURL)
}

@Test func enqueueTreatsTheSameNonFileSourceAsTheSameVideo() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let queue = JobQueue(store: store, runners: ["fake": PlainRunner()], startPaused: true)
    func photosJob(_ id: String) -> Job {
        Job(
            toolID: "fake", source: URL(string: "x-photos-asset:\(id)")!, sourceBookmark: Data(),
            settings: Data())
    }

    let added = await queue.enqueue([photosJob("A%2FL0%2F001"), photosJob("A%2FL0%2F001"), photosJob("B%2FL0%2F001")])

    #expect(added.count == 2)
}

@Test func aRunningJobFetchingItsInputIsDownloading() {
    var job = makeJob()
    #expect(!job.isDownloading)
    job.state = .running(progress: 0.2)
    job.phase = "Downloading from iCloud…"
    #expect(job.isDownloading)
    // Waiting for its turn at the one download at a time is still the download stage.
    job.phase = "Waiting for another download…"
    #expect(job.isDownloading)
    job.phase = "Converting…"
    #expect(!job.isDownloading)
    job.phase = "Downloading from iCloud…"
    job.state = .queued
    #expect(!job.isDownloading)
}
