import Foundation

/// What the Activity lists show, computed from the queue's jobs.
public struct ActivitySummary: Sendable, Equatable {
    /// Queued and running.
    public var queue = 0
    public var completed = 0
    public var keptAsIs = 0
    public var failed = 0
    /// Bytes freed by completed jobs.
    public var savedBytes: Int64 = 0
    /// The running jobs' progress, from 0 to 1 (the mean when several run); nil when nothing runs.
    public var runningProgress: Double?

    public init(jobs: [Job]) {
        var runningProgresses: [Double] = []
        defer {
            if !runningProgresses.isEmpty {
                runningProgress = runningProgresses.reduce(0, +) / Double(runningProgresses.count)
            }
        }
        for job in jobs {
            switch job.state {
            case .queued: queue += 1
            case .running(let progress):
                queue += 1
                runningProgresses.append(progress)
            case .completed(let outcome):
                completed += 1
                savedBytes += outcome.savedBytes
            case .keptAsIs: keptAsIs += 1
            case .failed: failed += 1
            }
        }
    }

    /// Nothing queued or running.
    public var isIdle: Bool { queue == 0 }
}

/// What one run of the queue did, from the first job taken to the queue running dry.
public struct QueueRunSummary: Sendable, Equatable {
    public var converted: Int
    public var savedBytes: Int64
    public var keptAsIs: Int
    public var failed: Int

    public init(converted: Int, savedBytes: Int64, keptAsIs: Int, failed: Int) {
        self.converted = converted
        self.savedBytes = savedBytes
        self.keptAsIs = keptAsIs
        self.failed = failed
    }
}

/// Watches queue snapshots and reports once when the queue finishes: nothing is queued or running any more after
/// at least one job finished since the last report.
///
/// The queue's update stream keeps only the newest snapshot, so a job can go from queued to finished (or appear
/// finished) between two snapshots. A job counts as finished in this run when it is finished now and was not in
/// that same state in the previous snapshot. Jobs already finished in the first snapshot (restored history) don't
/// count.
public struct QueueRunTracker: Sendable {
    private var previous: [UUID: JobState]?
    private var finished: [UUID: JobState] = [:]

    public init() {}

    /// Feeds the next snapshot; returns a summary when this snapshot ends a run.
    public mutating func observe(_ jobs: [Job]) -> QueueRunSummary? {
        defer { previous = Dictionary(jobs.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first }) }
        guard let previous else { return nil }
        for job in jobs {
            if job.state.isPending {
                finished[job.id] = nil
            } else if previous[job.id] != job.state {
                finished[job.id] = job.state
            }
        }
        guard !finished.isEmpty, !jobs.contains(where: { $0.state.isPending }) else { return nil }
        var summary = QueueRunSummary(converted: 0, savedBytes: 0, keptAsIs: 0, failed: 0)
        for state in finished.values {
            switch state {
            case .completed(let outcome):
                summary.converted += 1
                summary.savedBytes += outcome.savedBytes
            case .keptAsIs: summary.keptAsIs += 1
            case .failed: summary.failed += 1
            case .queued, .running: break
            }
        }
        finished.removeAll()
        return summary
    }
}
