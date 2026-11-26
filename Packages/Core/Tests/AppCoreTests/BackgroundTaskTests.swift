import Foundation
import MediaTestSupport
import Testing

@testable import AppCore

@MainActor
@Suite("Background continued processing")
struct BackgroundTaskTests {
    private enum TestError: Error {
        case ineligible
    }

    private actor PartialWritingRunner: JobRunner {
        let partialURL: URL
        private var gate: CheckedContinuation<Void, any Error>?
        private let startedContinuation: AsyncStream<Void>.Continuation
        nonisolated let started: AsyncStream<Void>

        init(partialURL: URL) {
            self.partialURL = partialURL
            (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        }

        func run(_ job: Job, progress: @escaping @Sendable (Double) -> Void) async throws -> JobState {
            try Data("partial-video-bytes".utf8).write(to: partialURL)
            progress(0.4)
            startedContinuation.yield()
            do {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        gate = continuation
                    }
                } onCancel: {
                    Task { await self.cancelRun() }
                }
                try? FileManager.default.removeItem(at: partialURL)
                return .completed(
                    JobOutcome(
                        output: partialURL.deletingLastPathComponent().appending(path: "clip (1080p).mov"),
                        bytesBefore: 1000,
                        bytesAfter: 400,
                        report: MetadataReport(),
                        replacedOriginal: false
                    )
                )
            } catch {
                try? FileManager.default.removeItem(at: partialURL)
                throw error
            }
        }

        private func cancelRun() {
            gate?.resume(throwing: CancellationError())
            gate = nil
        }

        func finish() {
            gate?.resume()
            gate = nil
        }
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "BackgroundTaskTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeJob(name: String = "clip") -> Job {
        Job(
            toolID: "convert",
            source: URL(fileURLWithPath: "/tmp/\(name).mov"),
            sourceBookmark: Data(),
            settings: Data()
        )
    }

    @Test func expirationRequeuesAndDiscardsPartial() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let partialURL = dir.appending(path: ".clip (1080p).mov.partial-\(UUID().uuidString)")
        let runner = PartialWritingRunner(partialURL: partialURL)
        let store = JobStore(directory: dir)
        let queue = JobQueue(store: store, runners: ["convert": runner], progressInterval: .zero)
        let scheduler = FakeBackgroundTaskScheduler()
        let coordinator = ContinuedProcessingCoordinator(
            scheduler: scheduler,
            identifierPrefix: "com.example.app.convert",
            onExpire: { await queue.pauseAndRequeueRunning() }
        )

        let updatesTask = Task { @MainActor in
            for await jobs in await queue.updates() {
                let runningJob = jobs.first {
                    if case .running = $0.state { return true }
                    return false
                }
                let progress: Double =
                    if case .running(let value) = runningJob?.state { value } else { 0 }
                let isPaused = await queue.isPaused()
                let isBusy = runningJob != nil || (jobs.contains { $0.state == .queued } && !isPaused)
                coordinator.update(
                    isRunning: isBusy,
                    title: runningJob?.source.lastPathComponent ?? "Converting Video",
                    subtitle: "Item 1 of 1",
                    progress: progress
                )
            }
        }
        defer { updatesTask.cancel() }

        var starts = runner.started.makeAsyncIterator()
        await queue.enqueue([makeJob()])
        await starts.next()

        // Allow the MainActor update loop to deliver the 0.4 progress update to the fake task.
        while (scheduler.launchOrder.last?.progressUpdates.last?.completed ?? 0) < 400 {
            await Task.yield()
        }

        let task = try #require(scheduler.launchOrder.last)
        #expect(scheduler.submittedRequests.count == 1)
        #expect(scheduler.submittedRequests[0].strategy == .fail)
        #expect(scheduler.submittedRequests[0].identifier.hasPrefix("com.example.app.convert."))
        #expect(task.hasExpirationHandler)
        #expect(task.progressUpdates.contains { $0.completed == 400 && $0.total == 1000 })
        #expect(FileManager.default.fileExists(atPath: partialURL.path))

        scheduler.expireLatest()
        while coordinator.expirationTask == nil {
            await Task.yield()
        }
        await coordinator.expirationTask?.value

        #expect(!FileManager.default.fileExists(atPath: partialURL.path))
        #expect(await queue.jobs.map(\.state) == [.queued])
        #expect(store.load().map(\.state) == [.queued])
        #expect(await queue.isPaused() == true)
        #expect(task.completedResults == [false])
        #expect(!coordinator.isActive)

        await queue.shutdown()
    }

    @Test func completionEndsBackgroundTaskWithSuccess() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let partialURL = dir.appending(path: ".clip (1080p).mov.partial-\(UUID().uuidString)")
        let runner = PartialWritingRunner(partialURL: partialURL)
        let queue = JobQueue(store: JobStore(directory: dir), runners: ["convert": runner], progressInterval: .zero)
        let scheduler = FakeBackgroundTaskScheduler()
        let coordinator = ContinuedProcessingCoordinator(
            scheduler: scheduler,
            identifierPrefix: "com.example.app.convert",
            onExpire: { await queue.pauseAndRequeueRunning() }
        )

        var starts = runner.started.makeAsyncIterator()
        await queue.enqueue([makeJob()])
        await starts.next()

        coordinator.update(isRunning: true, title: "clip.mov", subtitle: "Item 1 of 1", progress: 0.5)
        let task = try #require(scheduler.launchOrder.last)
        #expect(coordinator.isActive)

        await runner.finish()
        coordinator.update(isRunning: false, title: "", subtitle: "", progress: 0)
        #expect(task.completedResults == [true])
        #expect(!coordinator.isActive)

        await queue.shutdown()
    }

    @Test func submissionFailureContinuesInForegroundWithoutResubmitting() {
        let scheduler = FakeBackgroundTaskScheduler()
        scheduler.submitError = TestError.ineligible
        var failures = 0
        let coordinator = ContinuedProcessingCoordinator(
            scheduler: scheduler,
            identifierPrefix: "com.example.app.convert",
            onExpire: {},
            onSubmitFailure: { _ in failures += 1 }
        )

        coordinator.update(isRunning: true, title: "clip.mov", subtitle: "Item 1 of 1", progress: 0.1)
        coordinator.update(isRunning: true, title: "clip.mov", subtitle: "Item 1 of 1", progress: 0.2)
        coordinator.update(isRunning: true, title: "clip.mov", subtitle: "Item 1 of 1", progress: 0.3)

        #expect(failures == 1)
        #expect(scheduler.submittedRequests.count == 1)
        #expect(!coordinator.isActive)

        // Ending and starting a subsequent run attempts submission again.
        coordinator.update(isRunning: false, title: "", subtitle: "", progress: 0)
        scheduler.submitError = nil
        coordinator.update(isRunning: true, title: "clip2.mov", subtitle: "Item 1 of 1", progress: 0.1)
        #expect(scheduler.submittedRequests.count == 2)
        #expect(coordinator.isActive)
    }

    @Test func launchRecoveryResetsRunningJobAndClearsPhase() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = JobStore(directory: dir)
        var stuck = makeJob()
        stuck.state = .running(progress: 0.65)
        stuck.phase = "Downloading from iCloud…"
        try store.save([stuck])

        let queue = JobQueue(store: store, runners: [:])
        let loaded = store.load()
        #expect(loaded.map(\.state) == [.queued])
        #expect(loaded.first?.phase == nil)
        _ = queue
    }
}
