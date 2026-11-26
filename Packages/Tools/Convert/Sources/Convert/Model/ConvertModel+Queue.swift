import AppCore
import Foundation
import LocalLibrary

extension ConvertModel {
    /// The shared queue changed: mirror the originals waiting in Photos, and update the library items a Replace
    /// changed.
    func jobsChanged(_ jobs: [Job]) {
        pendingOriginals = services.pendingDeletions.all
        reconcileReplacedFiles(jobs)
    }

    /// A Replace put a smaller file where a library item was: update that item in place. The item is found by
    /// the file the run actually read (the job's path, or where its bookmark found the file after a move), else
    /// by the job's own path (a file moved in Finder this session: its item is still at the old path). Jobs
    /// finished before this session are taken as already reflected.
    private func reconcileReplacedFiles(_ jobs: [Job]) {
        let replaced = jobs.compactMap { job -> (id: UUID, sources: [URL], output: URL)? in
            guard case .completed(let outcome) = job.state, outcome.replacedOriginal, outcome.output.isFileURL else {
                return nil
            }
            return (job.id, [job.sourceUsed, job.source], outcome.output)
        }
        guard var handled = reconciledReplaceIDs else {
            reconciledReplaceIDs = Set(replaced.map(\.id))
            return
        }
        let library = self.library
        for job in replaced where handled.insert(job.id).inserted {
            Task { await library.fileWasReplaced(at: job.sources, by: job.output) }
        }
        reconciledReplaceIDs = handled
    }

    // MARK: - Lists

    public var queuedJobs: [Job] { jobs.filter(\.state.isPending) }

    // The finished lists show the most recently added first.

    public var completedJobs: [(job: Job, outcome: JobOutcome)] {
        jobs.reversed().compactMap { job in
            if case .completed(let outcome) = job.state { return (job, outcome) }
            return nil
        }
    }

    public var keptAsIsJobs: [(job: Job, reason: String)] {
        jobs.reversed().compactMap { job in
            if case .keptAsIs(let reason, _) = job.state { return (job, reason) }
            return nil
        }
    }

    public var failedJobs: [(job: Job, reason: String)] {
        jobs.reversed().compactMap { job in
            if case .failed(let reason, _) = job.state { return (job, reason) }
            return nil
        }
    }

    // MARK: - Queue commands (the shared queue's)

    public func toggleQueuePaused() { services.toggleQueuePaused() }
    public func remove(_ job: Job) { services.remove(job) }
    public func cancel(_ job: Job) { services.cancel(job) }
    public func cancelAll() { services.cancelAll() }
    public func retry(_ job: Job) { services.retry(job) }
    public func retryAllFailed() { services.retryAllFailed() }
}
