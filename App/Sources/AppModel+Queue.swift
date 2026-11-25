import AppCore
import DownscaleVideo
import Foundation
import LocalLibrary

/// Counts for the Activity rows in the sidebar.
struct ActivityCounts: Equatable {
    var queue = 0
    var completed = 0
    var keptAsIs = 0
    var failed = 0
}

extension AppModel {
    /// Starts the queue (auto-start; a setting arrives later) and mirrors its jobs. Safe to call more than once.
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        let queue = self.queue
        updatesTask = Task { [weak self] in
            for await jobs in await queue.updates() {
                self?.jobs = jobs
            }
        }
        await queue.resume()
    }

    /// Stops scanning (items found so far stay), lets library saves finish, and stops the queue before the app
    /// quits. The running job goes back to the queue and starts over next launch.
    func prepareForTermination() async {
        library.cancelScan()
        await library.waitUntilIdle()
        await queue.shutdown()
        updatesTask?.cancel()
    }

    var activityCounts: ActivityCounts {
        jobs.reduce(into: ActivityCounts()) { counts, job in
            switch job.state {
            case .queued, .running: counts.queue += 1
            case .completed: counts.completed += 1
            case .keptAsIs: counts.keptAsIs += 1
            case .failed: counts.failed += 1
            }
        }
    }

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

    /// One job per available selected video, with the current preset, Advanced spec and Save to choice.
    func addSelectionToQueue() {
        guard let destination = saveLocation.destination else { return }
        let settings = DownscaleJobSettings(preset: preset, saveTo: destination, custom: advanced.spec)
        do {
            let jobs = try JobFactory.makeJobs(for: queueableItems.map(\.url), settings: settings)
            let queue = self.queue
            Task { await queue.enqueue(jobs) }
        } catch {
            queueError = "Couldn't add to the queue: \(error.localizedDescription)"
        }
    }
}
