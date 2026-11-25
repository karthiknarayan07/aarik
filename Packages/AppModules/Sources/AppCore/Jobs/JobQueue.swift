import Foundation
import Synchronization
import os

/// Runs jobs one at a time, in order, persisting after every state change.
///
/// Nothing runs until the first `enqueue`, `resume` or `retry`; call `resume()` after
/// creating a queue to continue jobs restored from the store. A queue created with `startPaused`
/// runs nothing, enqueued or restored, until `resume()`.
public actor JobQueue {
    private let store: JobStore
    private let runners: [String: any JobRunner]
    private var items: [Job]
    private var paused = false
    /// The queue stopped itself (hot Mac, low battery). Separate from `paused`: `resume()` never clears it, and
    /// lifting it never clears the user's pause.
    private var heldAutomatically = false
    private var stopped = false
    private var worker: Task<Void, Never>?
    /// The job being run and its task, so `cancel` can stop just that job.
    private var current: (id: UUID, task: Task<JobState, any Error>)?
    /// Running jobs the user cancelled: when their run throws they leave the queue instead of failing.
    private var cancelledByUser: Set<UUID> = []
    private var subscribers: [UUID: AsyncStream<[Job]>.Continuation] = [:]
    /// Set when the saved queue couldn't be read (it was set aside, or it is left alone and this session's queue
    /// isn't saved); the queue starts empty.
    public private(set) var loadError: String?
    /// False when the saved queue couldn't be read or set aside: saving would overwrite it.
    private let savesChanges: Bool
    /// Progress alone is published at most once per interval; state changes go out at once (each also carries
    /// the latest progress).
    private let progressInterval: Duration
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AppCore", category: "queue")
    private var lastPublished: ContinuousClock.Instant?
    /// Publishes progress held back by `progressInterval` once the interval is up; a state change publishes it
    /// sooner and cancels this.
    private var heldProgress: Task<Void, Never>?

    public init(store: JobStore, runners: [String: any JobRunner], startPaused: Bool = false) {
        self.init(store: store, runners: runners, startPaused: startPaused, progressInterval: .milliseconds(100))
    }

    /// `progressInterval`: the shortest time between two updates for progress alone (a test seam).
    init(store: JobStore, runners: [String: any JobRunner], startPaused: Bool = false, progressInterval: Duration) {
        self.store = store
        self.runners = runners
        self.paused = startPaused
        self.progressInterval = progressInterval
        let result = store.loadReportingProblems()
        savesChanges = !result.mustNotSave
        if let aside = result.setAside {
            loadError = "The saved queue couldn't be read. It was kept as \(aside.lastPathComponent)."
        } else if result.mustNotSave {
            loadError =
                "The saved queue couldn't be read. It was left as it is, and changes to the queue won't be saved "
                + "until the app is opened again."
        }
        var loaded = result.jobs
        var recovered = false
        for index in loaded.indices {
            if case .running = loaded[index].state {
                loaded[index].state = .queued
                loaded[index].phase = nil
                recovered = true
            }
        }
        self.items = loaded
        if recovered, savesChanges { try? store.save(loaded) }
    }

    public var jobs: [Job] { items }

    /// Whether the user paused the queue.
    public func isPaused() -> Bool { paused }

    /// Whether the queue holds itself for the system (see `setAutomaticHold`).
    public func isHeldAutomatically() -> Bool { heldAutomatically }

    /// Appends the jobs and returns the ones actually added. A job whose file already has a queued or running job
    /// for the same tool is skipped, as is a repeat within `newJobs`; finished jobs don't block adding a file again.
    @discardableResult
    public func enqueue(_ newJobs: [Job]) -> [Job] {
        var pending = Set(items.filter(\.state.isPending).map(SourceKey.init))
        let added = newJobs.filter { pending.insert(SourceKey($0)).inserted }
        guard !added.isEmpty else { return [] }
        items.append(contentsOf: added)
        changed()
        startWorkerIfNeeded()
        return added
    }

    /// Lets the running job finish, then stops taking new ones.
    public func pause() {
        paused = true
    }

    public func resume() {
        paused = false
        startWorkerIfNeeded()
    }

    /// Holds the queue for the system (the Mac is too hot, the battery is low), like `pause` but on its own flag: the
    /// running job finishes, then nothing new starts. Lifting the hold restarts the queue unless the user paused it.
    public func setAutomaticHold(_ held: Bool) {
        heldAutomatically = held
        if !held { startWorkerIfNeeded() }
    }

    /// Puts a failed job back in the queue. Other states are ignored, and so is a failed job whose file already
    /// has a queued or running job for the same tool (it stays failed).
    public func retry(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        requeueFailed([index])
    }

    /// Puts every failed job back in the queue, except those whose file already has a queued or running job for
    /// the same tool, and all but the first of several failed jobs for one file. Skipped jobs stay failed.
    public func retryAllFailed() {
        requeueFailed(Array(items.indices))
    }

    private func requeueFailed(_ indices: [Int]) {
        var pending = Set(items.filter(\.state.isPending).map(SourceKey.init))
        var any = false
        for index in indices {
            guard case .failed = items[index].state, pending.insert(SourceKey(items[index])).inserted else {
                continue
            }
            items[index].state = .queued
            any = true
        }
        guard any else { return }
        changed()
        startWorkerIfNeeded()
    }

    /// Cancels a job: a running one is stopped (the runner removes its partial output and leaves the original
    /// untouched) and leaves the queue; a queued one is removed. Finished jobs are left alone. Unlike `shutdown`,
    /// a cancelled job is never put back in the queue. A run that finishes before the cancellation reaches it
    /// keeps its result.
    public func cancel(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch items[index].state {
        case .queued:
            items.remove(at: index)
            changed()
        case .running:
            guard let current, current.id == id else { return }
            cancelledByUser.insert(id)
            current.task.cancel()
        case .completed, .keptAsIs, .failed:
            return
        }
    }

    /// Removes every queued job and cancels the running one (see `cancel`). Finished jobs stay.
    public func cancelAll() {
        let before = items.count
        items.removeAll { $0.state == .queued }
        if items.count != before { changed() }
        if let current {
            cancelledByUser.insert(current.id)
            current.task.cancel()
        }
    }

    /// Removes a job unless it is running.
    public func remove(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if case .running = items[index].state { return }
        items.remove(at: index)
        changed()
    }

    /// Changes the outcome of a finished (completed) job and saves it: for what happens after the run, such as
    /// an original that was moved to Recently Deleted once the user confirmed. Other jobs are left alone.
    public func updateOutcome(id: UUID, transform: (inout JobOutcome) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }),
            case .completed(var outcome) = items[index].state
        else { return }
        transform(&outcome)
        items[index].state = .completed(outcome)
        changed()
    }

    /// Yields the current jobs immediately, then again after every change.
    public func updates() -> AsyncStream<[Job]> {
        let key = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: [Job].self, bufferingPolicy: .bufferingNewest(1))
        if stopped {
            continuation.yield(items)
            continuation.finish()
            return stream
        }
        subscribers[key] = continuation
        continuation.yield(items)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(key) }
        }
        return stream
    }

    /// Cancels the running job (it goes back to `.queued`), stops processing and
    /// finishes all update streams.
    public func shutdown() async {
        stopped = true
        let worker = self.worker
        worker?.cancel()
        await worker?.value
        heldProgress?.cancel()
        heldProgress = nil
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }

    // MARK: - Internals

    private func removeSubscriber(_ key: UUID) {
        subscribers[key] = nil
    }

    /// A state change: saved, and published at once.
    private func changed() {
        if savesChanges { try? store.save(items) }
        publish()
    }

    /// Sends the jobs to every subscriber; any held-back progress goes with them.
    private func publish() {
        heldProgress?.cancel()
        heldProgress = nil
        lastPublished = .now
        for continuation in subscribers.values { continuation.yield(items) }
    }

    /// Progress alone: published at most once per `progressInterval`, the latest value last.
    private func publishProgress() {
        guard let lastPublished else { return publish() }
        let wait = progressInterval - lastPublished.duration(to: .now)
        guard wait > .zero else { return publish() }
        guard heldProgress == nil else { return }
        heldProgress = Task { [weak self] in
            do {
                try await Task.sleep(for: wait)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.publishHeldProgress()
        }
    }

    /// Runs on the held task: once a state change cancelled it, it publishes nothing, even if a newer held
    /// publish is waiting.
    private func publishHeldProgress() {
        guard !Task.isCancelled, heldProgress != nil, !stopped else { return }
        publish()
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, !paused, !heldAutomatically, !stopped,
            items.contains(where: { $0.state == .queued })
        else { return }
        worker = Task { await self.drain() }
    }

    private func drain() async {
        while true {
            // No suspension between this check and clearing `worker`, so a concurrent
            // enqueue/resume either sees the worker still alive or starts a new one.
            guard !paused, !heldAutomatically, !stopped,
                let index = items.firstIndex(where: { $0.state == .queued })
            else {
                worker = nil
                return
            }
            let id = items[index].id
            items[index].state = .running(progress: 0)
            changed()
            let job = items[index]
            let result = await execute(job)
            apply(result, to: id)
        }
    }

    /// What happens to a job once its run ends.
    private enum Disposition {
        case finished(JobState)
        /// Shutdown: back in the queue, to start over next time.
        case requeue
        /// Cancelled by the user: out of the queue.
        case remove
    }

    private func execute(_ job: Job) async -> Disposition {
        guard let runner = runners[job.toolID] else {
            return .finished(.failed(reason: "No tool can run this job"))
        }
        let id = job.id
        // Progress arrives in order through a stream that keeps only the newest value, so a fast runner never
        // piles up work here; what reaches subscribers is throttled further (`publishProgress`).
        let (progressValues, progressSink) = AsyncStream.makeStream(
            of: RunProgress.self, bufferingPolicy: .bufferingNewest(1))
        let latest = Mutex(RunProgress())
        let progressReader = Task {
            for await value in progressValues { updateProgress(value, for: id) }
        }
        // Its own task, so `cancel` can stop this job alone; cancelling the worker (shutdown) cancels it too.
        let task = Task {
            try await runner.run(
                job,
                // Yielded inside the lock, so the stream sees the snapshots in the order they were made.
                progress: { value in
                    latest.withLock {
                        $0.progress = value
                        progressSink.yield($0)
                    }
                },
                phase: { name in
                    latest.withLock {
                        $0.phase = name
                        $0.progress = 0
                        progressSink.yield($0)
                    }
                })
        }
        current = (id, task)
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }
        progressSink.finish()
        await progressReader.value
        current = nil
        let cancelled = cancelledByUser.remove(id) != nil
        switch result {
        case .success(let state):
            return .finished(state)
        case .failure(let error):
            if cancelled { return .remove }
            // Only a cancelled worker (shutdown) is not a failure.
            if Task.isCancelled { return .requeue }
            // The sentence for the user; the full error (domain, code, user info) only to the log.
            Self.log.error("Job \(id, privacy: .public) failed: \(String(describing: error), privacy: .private)")
            return .finished(.failed(reason: Self.reason(for: error)))
        }
    }

    /// The sentence shown for a failure. A Swift error that isn't localized bridges to "The operation couldn't be
    /// completed. (… error N.)", which names types and codes; it is replaced by a plain sentence.
    static func reason(for error: any Error) -> String {
        let description = error.localizedDescription
        if description.hasPrefix("The operation couldn\u{2019}t be completed")
            || description.hasPrefix("The operation couldn't be completed")
        {
            return "The video couldn't be converted."
        }
        return description
    }

    private func apply(_ disposition: Disposition, to id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].phase = nil
        switch disposition {
        case .finished(let state): items[index].state = state
        case .requeue: items[index].state = .queued
        case .remove: items.remove(at: index)
        }
        changed()
    }

    private func updateProgress(_ value: RunProgress, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
            case .running = items[index].state
        else { return }
        items[index].state = .running(progress: min(max(value.progress, 0), 1))
        items[index].phase = value.phase
        publishProgress()
    }
}

/// What a run reported last: its phase and the progress within it.
private struct RunProgress: Sendable {
    var phase: String?
    var progress = 0.0
}

/// Identifies "the same file for the same tool" across spellings of its path.
struct SourceKey: Hashable {
    let toolID: String
    let path: String

    init(_ job: Job) {
        toolID = job.toolID
        path = Self.path(of: job.source)
    }

    /// The real path with symlinks and `..` resolved (`/tmp/a.mov` and `/private/tmp/a.mov` match). A missing file
    /// resolves through its parent folder; failing that, the standardized path.
    static func path(of url: URL) -> String {
        // Not a file (a Photos video's `x-photos-asset:` address): the address itself says which video it is.
        guard url.isFileURL else { return url.absoluteString }
        let standardized = url.standardizedFileURL
        if let real = realPath(standardized.path) { return real }
        let parent = standardized.deletingLastPathComponent().path
        if let real = realPath(parent) {
            return (real as NSString).appendingPathComponent(standardized.lastPathComponent)
        }
        return standardized.path
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

extension JobState {
    /// Queued or running: still to finish.
    public var isPending: Bool {
        switch self {
        case .queued, .running: true
        case .completed, .keptAsIs, .failed: false
        }
    }
}
