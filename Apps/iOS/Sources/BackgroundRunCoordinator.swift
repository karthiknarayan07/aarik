import AppCore
import AppServices
import Foundation
import Observation
import PhotosLibrary

/// Connects the iOS app's `AppServices` queue to `BGContinuedProcessingTask` via `ContinuedProcessingCoordinator`,
/// reporting current-item progress and cancelling + re-queuing cleanly if the background grant expires.
@MainActor
final class BackgroundRunCoordinator {
    static var defaultIdentifierPrefix: String {
        let bundleID = Bundle.main.bundleIdentifier ?? "app"
        return "\(bundleID).convert"
    }

    private let coordinator: ContinuedProcessingCoordinator
    private weak var observedServices: AppServices?
    private var observationTask: Task<Void, Never>?
    private var runBaselineFinished = 0

    init(
        services: AppServices,
        scheduler: any BackgroundTaskScheduler = SystemBackgroundTaskScheduler.shared,
        identifierPrefix: String = BackgroundRunCoordinator.defaultIdentifierPrefix,
        onSubmitFailure: (@MainActor (any Error) -> Void)? = nil
    ) {
        self.observedServices = services
        self.coordinator = ContinuedProcessingCoordinator(
            scheduler: scheduler,
            identifierPrefix: identifierPrefix,
            strategy: .fail,
            onExpire: { [weak services] in
                await services?.pauseForBackgroundExpiration()
            },
            onSubmitFailure: onSubmitFailure
        )
    }

    /// Sweeps stale Photos input folders left behind by an earlier crash or termination before the queue starts.
    nonisolated static func sweepWorkFolder() async {
        let workFolder = WorkFolder.standard()
        await Task.detached(priority: .utility) { workFolder.sweep() }.value
    }

    /// Starts observing `services` for job and pause changes. Safe to call once.
    func start() {
        guard let services = observedServices, observationTask == nil else { return }
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
        coordinator.update(isRunning: false, title: "", subtitle: "", progress: 0)
    }

    func sync(with services: AppServices) {
        let jobs = services.jobs
        let summary = services.activity
        let isAnyJobRunning = jobs.contains {
            if case .running = $0.state { return true }
            return false
        }
        let hasQueued = jobs.contains { $0.state == .queued }
        let isActiveRun = isAnyJobRunning || (hasQueued && !services.queuePause.isPaused)

        let totalFinished = summary.completed + summary.keptAsIs + summary.failed
        if !coordinator.isActive && isActiveRun {
            runBaselineFinished = totalFinished
        }

        guard isActiveRun else {
            coordinator.update(isRunning: false, title: "", subtitle: "", progress: 0)
            return
        }

        // The real stage in the system's own words for the task: "Converting 2 Videos" over "1 of 2 · Downloading from
        // iCloud · 42%", then the conversion's progress.
        let run = RunStatus(jobs: jobs, runBaselineFinished: runBaselineFinished)
        let title = run.title
        let subtitle = run.subtitle
        let progress = run.progress
        coordinator.update(isRunning: true, title: title, subtitle: subtitle, progress: progress)
    }
}
