import Foundation

/// Runs jobs one at a time, in order, persisting after every state change.
///
/// Nothing runs until the first `enqueue`, `resume` or `retry`; call `resume()` after
/// creating a queue to continue jobs restored from the store.
public actor JobQueue {
    private let store: JobStore
    private let runners: [String: any JobRunner]
    private var items: [Job]
    private var paused = false
    private var stopped = false
    private var worker: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<[Job]>.Continuation] = [:]

    public init(store: JobStore, runners: [String: any JobRunner]) {
        self.store = store
        self.runners = runners
        var loaded = store.load()
        var recovered = false
        for index in loaded.indices {
            if case .running = loaded[index].state {
                loaded[index].state = .queued
                recovered = true
            }
        }
        self.items = loaded
        if recovered { try? store.save(loaded) }
    }

    public var jobs: [Job] { items }

    public func isPaused() -> Bool { paused }

    public func enqueue(_ newJobs: [Job]) {
        guard !newJobs.isEmpty else { return }
        items.append(contentsOf: newJobs)
        changed()
        startWorkerIfNeeded()
    }

    /// Lets the running job finish, then stops taking new ones.
    public func pause() {
        paused = true
    }

    public func resume() {
        paused = false
        startWorkerIfNeeded()
    }

    /// Puts a failed job back in the queue. Other states are ignored.
    public func retry(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
            case .failed = items[index].state
        else { return }
        items[index].state = .queued
        changed()
        startWorkerIfNeeded()
    }

    public func retryAllFailed() {
        var any = false
        for index in items.indices {
            if case .failed = items[index].state {
                items[index].state = .queued
                any = true
            }
        }
        guard any else { return }
        changed()
        startWorkerIfNeeded()
    }

    /// Removes a job unless it is running.
    public func remove(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if case .running = items[index].state { return }
        items.remove(at: index)
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
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }

    // MARK: - Internals

    private func removeSubscriber(_ key: UUID) {
        subscribers[key] = nil
    }

    private func changed() {
        try? store.save(items)
        for continuation in subscribers.values { continuation.yield(items) }
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, !paused, !stopped,
            items.contains(where: { $0.state == .queued })
        else { return }
        worker = Task { await self.drain() }
    }

    private func drain() async {
        while true {
            // No suspension between this check and clearing `worker`, so a concurrent
            // enqueue/resume either sees the worker still alive or starts a new one.
            guard !paused, !stopped,
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

    private func execute(_ job: Job) async -> JobState? {
        guard let runner = runners[job.toolID] else {
            return .failed(reason: "No tool can run this job")
        }
        let id = job.id
        do {
            let state = try await runner.run(job) { [weak self] value in
                Task { await self?.updateProgress(value, for: id) }
            }
            return state
        } catch {
            // Only a cancelled worker (shutdown) is not a failure: nil means "put back in the queue".
            if Task.isCancelled { return nil }
            let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            return .failed(reason: reason)
        }
    }

    private func apply(_ result: JobState?, to id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = result ?? .queued
        changed()
    }

    private func updateProgress(_ value: Double, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
            case .running = items[index].state
        else { return }
        items[index].state = .running(progress: min(max(value, 0), 1))
        for continuation in subscribers.values { continuation.yield(items) }
    }
}
