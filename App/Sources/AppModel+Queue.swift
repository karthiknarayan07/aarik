import AppCore
import AppUI
import DownscaleVideo
import Foundation
import LocalLibrary

extension AppModel {
    /// Mirrors the queue's jobs and starts it, or holds it paused when auto-start is off. Safe to call more than
    /// once.
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        let queue = self.queue
        updatesTask = Task { [weak self] in
            for await jobs in await queue.updates() {
                self?.receive(jobs)
            }
        }
        if AppSettings.autoStartQueue(defaults) {
            await queue.resume()
        } else {
            await queue.pause()
        }
        isQueuePaused = await queue.isPaused()
    }

    /// Stops scanning (items found so far stay), lets library saves finish, and stops the queue before the app
    /// quits. The running job goes back to the queue and starts over next launch.
    func prepareForTermination() async {
        library.cancelScan()
        await library.waitUntilIdle()
        await lastQueueCommand?.value
        await queue.shutdown()
        updatesTask?.cancel()
    }

    private func receive(_ jobs: [Job]) {
        self.jobs = jobs
        activity = ActivitySummary(jobs: jobs)
        if let summary = runTracker.observe(jobs) {
            notifier.postUnlessFrontmost(title: "Queue finished", body: ActivityText.notificationBody(summary))
        }
    }

    // MARK: - Lists

    var queuedJobs: [Job] { jobs.filter(\.state.isPending) }

    // The finished lists show the most recently added first.

    var completedJobs: [(job: Job, outcome: JobOutcome)] {
        jobs.reversed().compactMap { job in
            if case .completed(let outcome) = job.state { return (job, outcome) }
            return nil
        }
    }

    var keptAsIsJobs: [(job: Job, reason: String)] {
        jobs.reversed().compactMap { job in
            if case .keptAsIs(let reason) = job.state { return (job, reason) }
            return nil
        }
    }

    var failedJobs: [(job: Job, reason: String)] {
        jobs.reversed().compactMap { job in
            if case .failed(let reason) = job.state { return (job, reason) }
            return nil
        }
    }

    // MARK: - Queue commands

    /// Sends a command to the queue after the previous one.
    private func send(_ command: @escaping @Sendable (JobQueue) async -> Void) {
        let previous = lastQueueCommand
        let queue = self.queue
        lastQueueCommand = Task {
            await previous?.value
            await command(queue)
        }
    }

    func toggleQueuePaused() {
        let pause = !isQueuePaused
        isQueuePaused = pause
        send { queue in
            if pause { await queue.pause() } else { await queue.resume() }
        }
    }

    func remove(_ job: Job) {
        let id = job.id
        send { await $0.remove(id) }
    }

    func retry(_ job: Job) {
        let id = job.id
        send { await $0.retry(id) }
    }

    func retryAllFailed() {
        send { await $0.retryAllFailed() }
    }

    // MARK: - Adding

    /// Available selected items; missing files can't be converted.
    var queueableItems: [LibraryItem] { selectedItems.filter(\.isAvailable) }

    var canAddSelectionToQueue: Bool { !queueableItems.isEmpty && saveLocation.destination != nil }

    var addToQueueTitle: String {
        QueueButtonTitle.title(count: queueableItems.count, preset: preset, isCustom: advanced.isEnabled)
    }

    /// Asks for confirmation before the first Replace of the session, otherwise adds right away.
    func requestAddSelectionToQueue() {
        guard canAddSelectionToQueue else { return }
        if saveLocation.choice == .replace, !hasConfirmedReplace {
            isConfirmingReplace = true
        } else {
            addSelectionToQueue()
        }
    }

    func confirmReplace() {
        hasConfirmedReplace = true
        addSelectionToQueue()
    }

    /// One job per available selected video, with the current preset, Advanced spec and Save to choice. Files that
    /// already wait or run in the queue are skipped by the queue. With auto-start on, the queue resumes.
    func addSelectionToQueue() {
        guard let destination = saveLocation.destination else { return }
        let settings = DownscaleJobSettings(preset: preset, saveTo: destination, custom: advanced.spec)
        do {
            let jobs = try JobFactory.makeJobs(for: queueableItems.map(\.url), settings: settings)
            let autoStart = AppSettings.autoStartQueue(defaults)
            if autoStart { isQueuePaused = false }
            send { queue in
                await queue.enqueue(jobs)
                if autoStart { await queue.resume() }
            }
            notifier.requestAuthorizationOnce()
        } catch {
            queueError = "Couldn't add to the queue: \(error.localizedDescription)"
        }
    }

    /// Puts the Settings window's Save to default into the inspector.
    func applyDefaultSaveLocation() {
        saveLocation = AppSettings.defaultSaveLocation(defaults)
    }
}
