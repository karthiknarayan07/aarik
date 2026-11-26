import Foundation
import Testing

@testable import AarikCore

private func job(_ name: String, _ state: JobState, tool: String = "fake", directory: String = "/tmp") -> Job {
    Job(
        toolID: tool, source: URL(fileURLWithPath: "\(directory)/\(name).mov"), sourceBookmark: Data(),
        settings: Data(), state: state)
}

private func outcome(before: Int64, after: Int64, warnings: [String] = []) -> JobOutcome {
    JobOutcome(
        output: URL(fileURLWithPath: "/tmp/out.mov"), bytesBefore: before, bytesAfter: after,
        report: MetadataReport(), replacedOriginal: false, warnings: warnings)
}

private func makeStore() throws -> (JobStore, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ActivityTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (JobStore(directory: dir), dir)
}

// MARK: - Summary

@Test func activityCounts() {
    let jobs = [
        job("a", .queued),
        job("b", .running(progress: 0.25)),
        job("c", .completed(outcome(before: 100, after: 40))),
        job("d", .completed(outcome(before: 50, after: 30, warnings: ["Audio is lost"]))),
        job("e", .keptAsIs(reason: "Already small")),
        job("f", .failed(reason: "boom")),
        job("g", .failed(reason: "boom")),
    ]
    let summary = ActivitySummary(jobs: jobs)
    #expect(summary.queue == 2)
    #expect(summary.completed == 2)
    #expect(summary.keptAsIs == 1)
    #expect(summary.failed == 2)
    #expect(summary.savedBytes == 80)
    #expect(summary.runningProgress == 0.25)
    #expect(!summary.isIdle)
    #expect(ActivitySummary(jobs: []).runningProgress == nil)
    #expect(ActivitySummary(jobs: [job("x", .keptAsIs(reason: "r"))]).isIdle)
}

@Test func savedBytesNeverNegative() {
    let bigger = job("a", .completed(outcome(before: 10, after: 30)))
    #expect(ActivitySummary(jobs: [bigger]).savedBytes == 0)
    #expect(outcome(before: 10, after: 30).savedBytes == 0)
}

// MARK: - Warnings

@Test func outcomeWithWarningsIsNotVerified() {
    #expect(outcome(before: 2, after: 1).isVerified)
    #expect(!outcome(before: 2, after: 1, warnings: ["Location is lost"]).isVerified)
}

@Test func outcomeDecodesWithoutWarningsKey() throws {
    // jobs.json written before warnings existed.
    let legacy = """
        {"bytesAfter":5,"bytesBefore":10,"output":"file:///tmp/a.mov",
         "replacedOriginal":true,"report":{"changed":[],"kept":[],"lost":[]}}
        """
    let decoded = try JSONDecoder().decode(JobOutcome.self, from: Data(legacy.utf8))
    #expect(decoded.warnings == [])
    #expect(decoded.replacedOriginal)
    let withWarnings = outcome(before: 2, after: 1, warnings: ["x"])
    let roundTrip = try JSONDecoder().decode(JobOutcome.self, from: JSONEncoder().encode(withWarnings))
    #expect(roundTrip == withWarnings)
}

@Test func outcomeNotesAndSourceDecodeWhenAbsentAndRoundTrip() throws {
    // jobs.json written before notes and the resolved source existed.
    let legacy = """
        {"bytesAfter":5,"bytesBefore":10,"output":"file:///tmp/a.mov",
         "replacedOriginal":true,"report":{"changed":[],"kept":[],"lost":[]},"warnings":[]}
        """
    let decoded = try JSONDecoder().decode(JobOutcome.self, from: Data(legacy.utf8))
    #expect(decoded.notes == [])
    #expect(decoded.source == nil)
    // Notes explain; they are not warnings.
    var noted = outcome(before: 2, after: 1)
    noted.addNote("Saved as a .mov file because MP4 can't hold all of its tracks", code: .containerChanged)
    noted.source = URL(fileURLWithPath: "/tmp/moved.mp4")
    #expect(noted.isVerified)
    let roundTrip = try JSONDecoder().decode(JobOutcome.self, from: JSONEncoder().encode(noted))
    #expect(roundTrip == noted)
}

@Test func replacedFileIsTheOneTheRunUsed() {
    var used = outcome(before: 2, after: 1)
    used.source = URL(fileURLWithPath: "/tmp/moved.mov")
    #expect(job("a", .completed(used)).sourceUsed == URL(fileURLWithPath: "/tmp/moved.mov"))
    // Older outcomes don't know; the job's own path stands in.
    #expect(job("a", .completed(outcome(before: 2, after: 1))).sourceUsed == URL(fileURLWithPath: "/tmp/a.mov"))
    #expect(job("a", .queued).sourceUsed == URL(fileURLWithPath: "/tmp/a.mov"))
}

// MARK: - Run tracking

@Test func runTrackerReportsWhenQueueDrains() {
    var tracker = QueueRunTracker()
    let a = job("a", .queued)
    let b = job("b", .queued)
    #expect(tracker.observe([a, b]) == nil)
    var running = a
    running.state = .running(progress: 0.5)
    #expect(tracker.observe([running, b]) == nil)
    var doneA = a
    doneA.state = .completed(outcome(before: 100, after: 40))
    var keptB = b
    keptB.state = .keptAsIs(reason: "Already small")
    let summary = tracker.observe([doneA, keptB])
    #expect(summary == QueueRunSummary(converted: 1, savedBytes: 60, keptAsIs: 1, failed: 0))
    // Nothing new ran: no second report.
    #expect(tracker.observe([doneA, keptB]) == nil)
}

@Test func runTrackerIgnoresRestoredHistory() {
    var tracker = QueueRunTracker()
    let old = job("a", .completed(outcome(before: 9, after: 1)))
    #expect(tracker.observe([old]) == nil)
    #expect(tracker.observe([old]) == nil)
}

@Test func runTrackerCountsJobsWhoseRunWasNotObserved() {
    // The update stream keeps only the newest value, so a fast job can go from queued to done unseen, or appear
    // already finished.
    var tracker = QueueRunTracker()
    let failed = job("a", .failed(reason: "boom"))
    #expect(tracker.observe([failed]) == nil)
    var retried = failed
    retried.state = .completed(outcome(before: 10, after: 4))
    let fresh = job("b", .failed(reason: "boom"))
    let summary = tracker.observe([retried, fresh])
    #expect(summary == QueueRunSummary(converted: 1, savedBytes: 6, keptAsIs: 0, failed: 1))
}

@Test func runTrackerWaitsWhilePausedWithQueuedJobs() {
    var tracker = QueueRunTracker()
    let a = job("a", .queued)
    let b = job("b", .queued)
    #expect(tracker.observe([a, b]) == nil)
    var doneA = a
    doneA.state = .completed(outcome(before: 2, after: 1))
    #expect(tracker.observe([doneA, b]) == nil)
    var doneB = b
    doneB.state = .failed(reason: "x")
    #expect(tracker.observe([doneA, doneB]) == QueueRunSummary(converted: 1, savedBytes: 1, keptAsIs: 0, failed: 1))
}

// MARK: - Queue

/// Reads the queue's update stream until `predicate` holds.
private func waitUntil(_ queue: JobQueue, _ predicate: @Sendable ([Job]) -> Bool) async {
    for await jobs in await queue.updates() where predicate(jobs) { return }
}

@Test func duplicateEnqueueIsSkipped() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let queue = JobQueue(store: store, runners: [:])
    await queue.pause()
    let first = job("a", .queued)
    let added = await queue.enqueue([first])
    #expect(added.map(\.id) == [first.id])

    // Same file (spelled differently, through a symlinked directory) and the same tool: skipped. Same file, other
    // tool: added. A repeat inside one batch: only the first is added.
    let sameFile = job("a", .queued, directory: "/private/tmp/../tmp")
    let otherTool = job("a", .queued, tool: "other")
    let b1 = job("b", .queued)
    let b2 = job("b", .queued)
    let second = await queue.enqueue([sameFile, otherTool, b1, b2])
    #expect(second.map(\.id) == [otherTool.id, b1.id])
    #expect(await queue.jobs.map(\.id) == [first.id, otherTool.id, b1.id])
}

@Test func finishedJobCanBeAddedAgain() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let queue = JobQueue(store: store, runners: [:])
    let first = job("a", .queued, tool: "nope")
    await queue.enqueue([first])
    await waitUntil(queue) { $0.first?.state == .failed(reason: "No tool can run this job", code: .noToolForJob) }
    await queue.pause()
    let again = job("a", .queued, tool: "nope")
    #expect(await queue.enqueue([again]).map(\.id) == [again.id])
}

@Test func retryAllRequeuesFailed() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let queue = JobQueue(store: store, runners: [:])
    let jobs = ["a", "b", "c"].map { job($0, .queued, tool: "nope") }
    await queue.enqueue(jobs)
    await waitUntil(queue) {
        $0.count == 3 && $0.allSatisfy { $0.state == .failed(reason: "No tool can run this job", code: .noToolForJob) }
    }
    #expect(ActivitySummary(jobs: await queue.jobs).failed == 3)

    await queue.pause()
    await queue.retryAllFailed()
    let summary = ActivitySummary(jobs: await queue.jobs)
    #expect(summary.failed == 0)
    #expect(summary.queue == 3)
    await queue.shutdown()
}
