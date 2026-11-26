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

        let currentJob =
            jobs.first {
                if case .running = $0.state { return true }
                return false
            } ?? jobs.first { $0.state == .queued }

        let progress: Double =
            if case .running(let value) = currentJob?.state { value } else { 0 }

        let runFinished = max(0, totalFinished - runBaselineFinished)
        let runTotal = max(1, runFinished + summary.queue)
        let itemIndex = min(runTotal, runFinished + 1)

        let title = Self.displayTitle(for: currentJob)
        let subtitle = Self.displaySubtitle(for: currentJob, itemIndex: itemIndex, totalItems: runTotal)
        coordinator.update(isRunning: true, title: title, subtitle: subtitle, progress: progress)
    }

    private static func displayTitle(for job: Job?) -> String {
        guard let job else { return "Shrinking Video" }
        if job.source.isFileURL {
            let name = job.source.deletingPathExtension().lastPathComponent
            if !name.isEmpty { return name }
        }
        return "Shrinking Video"
    }

    private static func displaySubtitle(for job: Job?, itemIndex: Int, totalItems: Int) -> String {
        let countLabel = totalItems > 1 ? "Item \(itemIndex) of \(totalItems)" : "Shrinking video"
        if let phase = job?.phase, !phase.isEmpty {
            return totalItems > 1 ? "\(countLabel) — \(phase)" : phase
        }
        return countLabel
    }
}
