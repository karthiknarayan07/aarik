import Foundation
import Synchronization
import os

/// Runs jobs in order, up to `concurrency` at a time (one unless `setConcurrency` says otherwise), persisting after
/// every state change. Jobs start in queue order; a job that finishes lets the next waiting one start.
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
    /// How many jobs may run at once. Lowering it never stops a running job: fewer start until enough have finished.
    private var concurrency: Int
    /// The jobs being run, each in a task of its own, so `cancel` can stop just that job and `shutdown` all of them.
    private var running: [UUID: Task<Void, Never>] = [:]
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

    public init(
        store: JobStore, runners: [String: any JobRunner], startPaused: Bool = false, concurrency: Int = 1
    ) {
        self.init(
            store: store, runners: runners, startPaused: startPaused, concurrency: concurrency,
            progressInterval: .milliseconds(100))
    }

    /// `progressInterval`: the shortest time between two updates for progress alone (a test seam).
    init(
        store: JobStore, runners: [String: any JobRunner], startPaused: Bool = false, concurrency: Int = 1,
        progressInterval: Duration
    ) {
        self.store = store
        self.runners = runners
        self.paused = startPaused
        self.concurrency = max(1, concurrency)
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

    /// How many jobs may run at once now.
    public func currentConcurrency() -> Int { concurrency }

    /// Changes how many jobs may run at once (at least one). Raising it starts waiting jobs at once; lowering it never
    /// stops a running job, it only holds back new ones until enough have finished.
    public func setConcurrency(_ count: Int) {
        concurrency = max(1, count)
        startWorkerIfNeeded()
    }

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

    /// Lets the running jobs finish, then stops taking new ones.
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
            guard let task = running[id] else { return }
            cancelledByUser.insert(id)
            task.cancel()
        case .completed, .keptAsIs, .failed:
            return
        }
    }

    /// Removes every queued job and cancels the running ones (see `cancel`). Finished jobs stay.
    public func cancelAll() {
        let before = items.count
        items.removeAll { $0.state == .queued }
        if items.count != before { changed() }
        for (id, task) in running {
            cancelledByUser.insert(id)
            task.cancel()
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

    /// Cancels the running jobs (they go back to `.queued`), stops processing and
    /// finishes all update streams.
    public func shutdown() async {
        stopped = true
        let tasks = Array(running.values)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
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

    /// Starts queued jobs, in order, until `concurrency` are running. Synchronous, so a caller never sees a
    /// half-started job.
    private func startWorkerIfNeeded() {
        while !paused, !heldAutomatically, !stopped, running.count < concurrency,
            let index = items.firstIndex(where: { $0.state == .queued })
        {
            let job = items[index]
            items[index].state = .running(progress: 0)
            changed()
            running[job.id] = Task { await self.drive(job) }
        }
    }

    /// Runs one job to its end, then lets the next waiting one start.
    private func drive(_ job: Job) async {
        let result = await execute(job)
        running[job.id] = nil
        apply(result, to: job.id)
        startWorkerIfNeeded()
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
            return .finished(.failed(reason: Self.noToolReason, code: .noToolForJob))
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
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }
        progressSink.finish()
        await progressReader.value
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
            let failure = Self.failure(for: error)
            return .finished(.failed(reason: failure.reason, code: failure.code))
        }
    }

    static let noToolReason = "No tool can run this job"

    static let genericFailureReason = "The video couldn't be converted."

    /// The sentence and the code for a failed run. The code is decided by what the error is (its type, or its domain
    /// and code for a system error), never by its words, which the system translates. An error of the app's own
    /// carries its code and its sentence. For a file error from Foundation the sentence is the system's own, in the
    /// user's language, unless that is the generic "operation couldn't be completed (error N)" form, which names a
    /// domain and a number; then it is one of ours. Anything else is the generic sentence.
    static func failure(for error: any Error) -> (reason: String, code: OutcomeCode) {
        if let coded = error as? any OutcomeCoded {
            let sentence = (error as? any LocalizedError)?.errorDescription ?? genericFailureReason
            return (sentence, coded.outcomeCode)
        }
        let nsError = error as NSError
        let known = knownSystemFailure(domain: nsError.domain, code: nsError.code)
        if [NSCocoaErrorDomain, NSPOSIXErrorDomain, NSURLErrorDomain].contains(nsError.domain) {
            let own = nsError.localizedDescription
            let readable = !own.isEmpty && !mentionsNumber(nsError.code, in: own)
            return (readable ? own : known?.sentence ?? genericFailureReason, known?.code ?? .conversionFailed)
        }
        // A Swift error of ours or a library's that words itself keeps its sentence; a system error of another
        // domain (AVFoundation, Photos, Core Media) is not shown in its own words, which are often the generic form.
        if !isSystemDomain(nsError.domain), let sentence = (error as? any LocalizedError)?.errorDescription {
            return (sentence, .conversionFailed)
        }
        return (known?.sentence ?? genericFailureReason, known?.code ?? .conversionFailed)
    }

    /// The kind of a few common system errors, by domain and code.
    private static func knownSystemFailure(domain: String, code: Int) -> (sentence: String, code: OutcomeCode)? {
        switch (domain, code) {
        case (NSCocoaErrorDomain, CocoaError.fileNoSuchFile.rawValue),
            (NSCocoaErrorDomain, CocoaError.fileReadNoSuchFile.rawValue),
            (NSPOSIXErrorDomain, Int(ENOENT)):
            return ("The original file is missing or the drive isn't connected.", .originalUnavailable)
        case (NSCocoaErrorDomain, CocoaError.fileWriteOutOfSpace.rawValue), (NSPOSIXErrorDomain, Int(ENOSPC)):
            return ("There isn't enough free space on this Mac.", .notEnoughSpace)
        case (NSCocoaErrorDomain, CocoaError.fileWriteNoPermission.rawValue),
            (NSCocoaErrorDomain, CocoaError.fileWriteVolumeReadOnly.rawValue),
            (NSPOSIXErrorDomain, Int(EROFS)):
            return ("The output folder can't be written to.", .outputFolderUnavailable)
        case (NSCocoaErrorDomain, CocoaError.fileReadNoPermission.rawValue), (NSPOSIXErrorDomain, Int(EACCES)),
            (NSPOSIXErrorDomain, Int(EPERM)):
            return ("The app doesn't have permission to read or write a file this job needs.", .conversionFailed)
        default:
            return nil
        }
    }

    /// Whether `text` holds `code` as a number of its own, as the generic "(Cocoa error 4.)" form does. A false
    /// match only means the app's own sentence is shown instead.
    private static func mentionsNumber(_ code: Int, in text: String) -> Bool {
        text.range(of: "(?<![0-9])\(code)(?![0-9])", options: .regularExpression) != nil
    }

    /// Error domains the system owns (Foundation, AVFoundation, Photos, Core Media, Core Animation and the
    /// reverse-DNS ones). A Swift error's domain is its type's name, which starts with a module name instead.
    private static func isSystemDomain(_ domain: String) -> Bool {
        ["NS", "AV", "PH", "CM", "CA", "kCF", "com.apple."].contains { domain.hasPrefix($0) }
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
