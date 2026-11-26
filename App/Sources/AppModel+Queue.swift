import AppCore
import AppKit
import AppUI
import DownscaleVideo
import Foundation
import LocalLibrary
import QuickRunService

extension AppModel {
    /// Mirrors the queue's jobs and starts it unless it was created paused (auto-start off). Safe to call more
    /// than once.
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        await startPressure()
        await quickRun.start()
        let queue = self.queue
        let loadError = await queue.loadError
        queueLoadFailed = loadError != nil
        updatesTask = Task { [weak self] in
            for await jobs in await queue.updates() {
                self?.receive(jobs)
            }
        }
        if let loadError {
            alert = AppAlert(title: "Couldn't read the queue", message: loadError)
        }
        // Copies of action inputs that no waiting job reads are left over from a crash or quit.
        let stillRead = await queue.jobs.filter(StagedInputs.isNeeded(by:)).map(\.source)
        let staged = stagedInputs
        await Task.detached(priority: .utility) { staged.sweep(keeping: stillRead) }.value
        // A queue created paused (auto-start off) waits for Resume.
        if !isQueuePaused { await queue.resume() }
        hasFinishedStarting = true
        let waiters = startWaiters
        startWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// Returns once `start()` has finished: the work-folder sweep is done and the queue is running, so what an
    /// entry point adds can't start a job too early.
    func waitUntilStarted() async {
        guard !hasFinishedStarting else { return }
        await withCheckedContinuation { startWaiters.append($0) }
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
        refreshQueuePause()
        activity = ActivitySummary(jobs: jobs)
        // A saved copy is only needed while its job can still be put back in the queue.
        if !queueLoadFailed {
            pendingDeletions.keepSavedCopies(
                forJobs: Set(
                    jobs.filter { job in
                        switch job.state {
                        case .completed, .keptAsIs: false
                        case .queued, .running, .failed: true
                        }
                    }.map(\.id)))
        }
        pendingOriginals = pendingDeletions.all
        menuBarRuns.dropStale(presentJobs: Set(jobs.map(\.id)))
        // A quick run announces itself; the generic "Queue finished" is for the window's jobs.
        let quickRunJobs = quickRunStore.jobIDs
        let windowJobs = quickRunJobs.isEmpty ? jobs : jobs.filter { !quickRunJobs.contains($0.id) }
        if let summary = runTracker.observe(windowJobs) {
            // Quiet only when the app is active with its window on screen; the Activity lists show the result.
            if NotificationPolicy.shouldPost(appIsActive: NSApp.isActive, windowOnScreen: isMainWindowVisible) {
                notifier.post(title: "Queue finished", body: ActivityText.notificationBody(summary))
            }
            // The run is over: ask Photos, once, to move the originals of its Replace jobs.
            moveOriginalsAfterRun()
        }
        reconcileReplacedFiles(jobs)
        if !stagedWatch.isEmpty { Task { await releaseStagedInputs() } }
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
    func send(_ command: @escaping @Sendable (JobQueue) async -> Void) {
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

    /// Stops the job if it is converting (its partial file is removed, the original untouched) and takes it out
    /// of the queue.
    func cancel(_ job: Job) {
        let id = job.id
        send { await $0.cancel(id) }
    }

    /// Empties the queue and stops the conversion in progress.
    func cancelAll() {
        send { await $0.cancelAll() }
    }

    func retry(_ job: Job) {
        let id = job.id
        send { await $0.retry(id) }
    }

    func retryAllFailed() {
        send { await $0.retryAllFailed() }
    }

    /// Puts the Settings window's Save to default into the inspector.
    func applyDefaultSaveLocation() {
        saveLocation = AppSettings.defaultSaveLocation(defaults)
    }
}
