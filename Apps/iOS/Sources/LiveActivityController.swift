import ActivityKit
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
        sync(with: services)
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
        endActivity(finalState: nil, dismissalPolicy: .immediate)
    }

    func sync(with services: AppServices) {
        let summary = services.activity
        let pause = services.queuePause
        let totalFinished = summary.completed + summary.keptAsIs + summary.failed

        // User paused: end immediately.
        if pause.isPausedByUser {
            endActivity(finalState: nil, dismissalPolicy: .immediate)
            return
        }

        // Queue is idle: end with a summary if work completed, or immediately if cancelled.
        if summary.isIdle {
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
                endActivity(finalState: finalState, dismissalPolicy: .after(.now.addingTimeInterval(Self.finishedDismissDelay)))
            } else {
                endActivity(finalState: nil, dismissalPolicy: .immediate)
            }
            return
        }

        // Active run (or waiting on thermal/battery while items remain).
        if activeActivity == nil {
            runBaselineFinished = totalFinished
            runBaselineCompleted = summary.completed
        }

        let finishedInRun = max(0, totalFinished - runBaselineFinished)
        let totalItems = max(1, finishedInRun + summary.queue)
        let runningFraction = summary.runningProgress ?? 0
        let wholeProgress = min(max((Double(finishedInRun) + runningFraction) / Double(totalItems), 0), 1)

        let status: ConvertActivityAttributes.ContentState.Status =
            switch pause.automatic {
            case .thermal: .waitingThermal
            case .batteryLow: .waitingBattery
            case nil: .running
            }

        let state = ConvertActivityAttributes.ContentState(
            itemsRemaining: summary.queue,
            totalItems: totalItems,
            progress: wholeProgress,
            savedBytes: summary.savedBytes,
            status: status
        )

        if activeActivity == nil {
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
            activeActivity = try Activity.request(attributes: attributes, content: content, pushType: nil)
            lastSentState = state
            lastUpdateAt = .now
            pendingState = nil
        } catch {
            activeActivity = nil
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
