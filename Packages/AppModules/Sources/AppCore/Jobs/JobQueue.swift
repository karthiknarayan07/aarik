import Foundation

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
    private var stopped = false
    private var worker: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<[Job]>.Continuation] = [:]

    public init(store: JobStore, runners: [String: any JobRunner], startPaused: Bool = false) {
        self.store = store
        self.runners = runners
        self.paused = startPaused
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
