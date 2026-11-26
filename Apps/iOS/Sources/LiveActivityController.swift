@preconcurrency import ActivityKit
import AppCore
import AppServices
import Foundation
import Observation

/// Manages the `ActivityKit` Live Activity for whole-queue conversion progress, throttled to at most 1 update/second.
@MainActor
final class LiveActivityController {
    private static let minimumUpdateInterval: Duration = .seconds(1)
    private static let finishedDismissDelay: TimeInterval = 300

    private weak var observedServices: AppServices?
    private var observationTask: Task<Void, Never>?
    private var activeActivity: Activity<ConvertActivityAttributes>?
    private var lastSentState: ConvertActivityAttributes.ContentState?
    private var lastUpdateAt: ContinuousClock.Instant?
    private var pendingState: ConvertActivityAttributes.ContentState?
    private var scheduledFlushTask: Task<Void, Never>?
    private var lastOperation: Task<Void, Never>?

    private var runBaselineFinished = 0
    private var runBaselineCompleted = 0
    /// Watches the system's view of the current activity: if it ends one we still need, the next sync asks again.
    private var stateWatchTask: Task<Void, Never>?
    /// The user swiped this run's activity away: it stays away until the run is over.
    private var userDismissedThisRun = false
    /// A run is under way (set at its first sync, cleared when it ends), so a fresh activity requested in the middle
    /// of it keeps the run's own baseline.
    private var runInProgress = false
    /// How many times the system ended this run's activity under us; a few fresh requests, then it stays ended.
    private var systemEndsThisRun = 0

    init(services: AppServices) {
        self.observedServices = services
    }

    /// Ends any orphaned Live Activities from a previous launch and begins observing `services`.
    func start() {
        guard let services = observedServices, observationTask == nil else { return }
        cleanupStaleActivities()
        services.observeJobs { [weak self, weak services] _ in
            guard let self, let services else { return }
            self.sync(with: services)
        }
        observationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let services = self.observedServices else { return }
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = services.queuePause
                        _ = services.isQueuePaused
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled, let services = self.observedServices else { return }
                self.sync(with: services)
            }
        }
        // The first request can be answered before the "Allow Live Activities?" decision is in; when the person
        // decides, start (or restart) at once instead of waiting for the next queue change.
        Task { [weak self] in
            for await _ in ActivityAuthorizationInfo().activityEnablementUpdates {
                guard let self, let services = self.observedServices else { return }
                self.sync(with: services)
            }
        }
        sync(with: services)
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
        endActivity(finalState: nil, dismissalPolicy: .immediate)
    }

    /// The Live Activity's state for a run: the real stage (downloading from iCloud, or converting) with the run's
    /// progress, a pause for heat, or the low-battery warning. A pure function of the jobs, so it is tested without
    /// ActivityKit.
    static func makeState(
        jobs: [Job], pause: QueuePause, runBaselineFinished: Int
    ) -> ConvertActivityAttributes.ContentState {
        let run = RunStatus(jobs: jobs, runBaselineFinished: runBaselineFinished)
        let status: ConvertActivityAttributes.ContentState.Status =
            switch pause.automatic {
            case .thermal: .waitingThermal
            case nil: run.isDownloading ? .downloading : .running
            }
        return ConvertActivityAttributes.ContentState(
            itemsRemaining: run.itemsRemaining,
            totalItems: run.totalItems,
            progress: run.progress,
            savedBytes: ActivitySummary(jobs: jobs).savedBytes,
            status: status,
            detail: run.detail,
            lowBattery: pause.lowBattery
        )
    }

    func sync(with services: AppServices) {
        let summary = services.activity
        let pause = services.queuePause
        let totalFinished = summary.completed + summary.keptAsIs + summary.failed

        // User paused: end immediately.
        if pause.isPausedByUser {
            userDismissedThisRun = false
            systemEndsThisRun = 0
            runInProgress = false
            endActivity(finalState: nil, dismissalPolicy: .immediate)
            return
        }

        // Queue is idle: end with a summary if work completed, or immediately if cancelled.
        if summary.isIdle {
            userDismissedThisRun = false
            systemEndsThisRun = 0
            runInProgress = false
            guard activeActivity != nil else { return }
            let completedInRun = max(0, summary.completed - runBaselineCompleted)
            let finishedInRun = max(0, totalFinished - runBaselineFinished)
            if completedInRun > 0 {
                let finalState = ConvertActivityAttributes.ContentState(
                    itemsRemaining: 0,
                    totalItems: max(1, finishedInRun),
                    progress: 1.0,
                    savedBytes: summary.savedBytes,
                    status: .finished
                )
                endActivity(
                    finalState: finalState, dismissalPolicy: .after(.now.addingTimeInterval(Self.finishedDismissDelay)))
            } else {
                endActivity(finalState: nil, dismissalPolicy: .immediate)
            }
            return
        }

        // Active run (or waiting on heat while items remain).
        if !runInProgress {
            runInProgress = true
            runBaselineFinished = totalFinished
            runBaselineCompleted = summary.completed
        }

        // A queued or running video keeps the activity alive, whatever stage it is in: nothing below ends it.
        let state = Self.makeState(
            jobs: services.jobs, pause: pause, runBaselineFinished: runBaselineFinished)

        if activeActivity == nil {
            guard !userDismissedThisRun, systemEndsThisRun <= 3 else { return }
            startActivity(with: state)
        } else {
            enqueueUpdate(state)
        }
    }

    private func cleanupStaleActivities() {
        let stale = Activity<ConvertActivityAttributes>.activities
        guard !stale.isEmpty else { return }
        enqueueOperation {
            for item in stale {
                await item.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private func startActivity(with state: ConvertActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = ConvertActivityAttributes()
        let content = ActivityContent(state: state, staleDate: nil)
        do {
            let activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
            activeActivity = activity
            lastSentState = state
            lastUpdateAt = .now
            pendingState = nil
            watch(activity)
        } catch {
            activeActivity = nil
        }
    }

    /// The system can end an activity on its own (one requested before the "Allow Live Activities?" decision is
    /// answered is ended when the answer arrives) or the person can swipe it away. Updates sent to an ended
    /// activity go nowhere, so a run that is still going must notice: a system end clears the reference so the next
    /// sync asks for a fresh one; a swipe is the person's choice and holds until the run is over.
    private func watch(_ activity: Activity<ConvertActivityAttributes>) {
        stateWatchTask?.cancel()
        stateWatchTask = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard let self, !Task.isCancelled else { return }
                guard self.activeActivity?.id == activity.id else { return }
                switch state {
                case .dismissed:
                    self.userDismissedThisRun = true
                    self.activeActivity = nil
                    self.lastSentState = nil
                    self.lastUpdateAt = nil
                    return
                case .ended:
                    self.systemEndsThisRun += 1
                    self.activeActivity = nil
                    self.lastSentState = nil
                    self.lastUpdateAt = nil
                    if self.systemEndsThisRun <= 3, let services = self.observedServices {
                        self.sync(with: services)
                    }
                    return
                default:
                    continue
                }
            }
        }
    }

    private func enqueueUpdate(_ state: ConvertActivityAttributes.ContentState) {
        guard state != lastSentState else {
            pendingState = nil
            return
        }
        guard let lastUpdateAt else {
            sendUpdate(state)
            return
        }
        let elapsed = lastUpdateAt.duration(to: .now)
        if elapsed >= Self.minimumUpdateInterval {
            sendUpdate(state)
            return
        }
        pendingState = state
        guard scheduledFlushTask == nil else { return }
        let remaining = Self.minimumUpdateInterval - elapsed
        scheduledFlushTask = Task { [weak self] in
            do {
                try await Task.sleep(for: remaining)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.scheduledFlushTask = nil
            if let pending = self.pendingState {
                self.pendingState = nil
                self.sendUpdate(pending)
            }
        }
    }

    private func sendUpdate(_ state: ConvertActivityAttributes.ContentState) {
        scheduledFlushTask?.cancel()
        scheduledFlushTask = nil
        pendingState = nil
        guard let activity = activeActivity else { return }
        guard state != lastSentState else { return }
        lastSentState = state
        lastUpdateAt = .now
        let content = ActivityContent(state: state, staleDate: nil)
        enqueueOperation {
            await activity.update(content)
        }
    }

    private func endActivity(
        finalState: ConvertActivityAttributes.ContentState?,
        dismissalPolicy: ActivityUIDismissalPolicy
    ) {
        scheduledFlushTask?.cancel()
        scheduledFlushTask = nil
        pendingState = nil
        guard let activity = activeActivity else { return }
        stateWatchTask?.cancel()
        stateWatchTask = nil
        activeActivity = nil
        lastSentState = nil
        lastUpdateAt = nil
        let content = finalState.map { ActivityContent(state: $0, staleDate: nil) }
        enqueueOperation {
            await activity.end(content, dismissalPolicy: dismissalPolicy)
        }
    }

    private func enqueueOperation(_ work: @escaping @Sendable () async -> Void) {
        let previous = lastOperation
        lastOperation = Task {
            await previous?.value
            await work()
        }
    }
}
