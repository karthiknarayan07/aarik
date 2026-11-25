import Foundation

/// Holds an update's install-and-relaunch while the queue is working, then lets it go once the queue is idle.
///
/// Busy means a job is running, or jobs are waiting and the queue isn't paused. A paused queue with waiting jobs is
/// idle: the user stopped it on purpose, and the waiting jobs are saved with the queue and restored on the next
/// launch, so a relaunch loses nothing. (Otherwise a paused queue would hold the update forever.)
@MainActor
public final class RelaunchGate {
    private var proceed: (@MainActor () -> Void)?
    public private(set) var isBusy = false

    public init() {}

    /// Whether work is under way for these jobs.
    public nonisolated static func isBusy(jobs: [Job], isQueuePaused: Bool) -> Bool {
        if jobs.contains(where: { if case .running = $0.state { true } else { false } }) { return true }
        return !isQueuePaused && jobs.contains { $0.state == .queued }
    }

    /// Records the queue's state; when it just became idle, runs the held relaunch once.
    public func update(jobs: [Job], isQueuePaused: Bool) {
        isBusy = Self.isBusy(jobs: jobs, isQueuePaused: isQueuePaused)
        releaseIfIdle()
    }

    /// Returns true when the relaunch must wait: `proceed` then runs once, as soon as the queue is idle. Returns
    /// false when the queue is idle and the caller should relaunch now; `proceed` is not kept.
    public func postpone(until proceed: @escaping @MainActor () -> Void) -> Bool {
        guard isBusy else {
            self.proceed = nil
            return false
        }
        self.proceed = proceed
        return true
    }

    private func releaseIfIdle() {
        guard !isBusy, let held = proceed else { return }
        proceed = nil
        held()
    }
}
