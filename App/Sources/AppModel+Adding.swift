import AppCore
import AppUI
import DownscaleVideo
import Foundation
import LocalLibrary

/// Videos that would lose metadata, each with what it loses and whether the user chose to skip it.
struct LossReview {
    struct Entry: Identifiable {
        let id: UUID
        let name: String
        let lost: [String]
        var skip = false
    }

    var entries: [Entry]
    /// Every video to add, lossy or not, in grid order.
    let items: [LibraryItem]
    let settings: DownscaleJobSettings
    /// What each lossy file loses, for the jobs' badges.
    let losses: [URL: [String]]
}

extension AppModel {
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

    /// Re-checks which files are still there, then adds one job per available selected video with the current
    /// preset, Advanced spec and Save to choice. Videos that would lose metadata are listed for the user first
    /// (`lossReview`); the rest go straight in.
    func addSelectionToQueue() {
        guard let destination = saveLocation.destination else { return }
        let settings = DownscaleJobSettings(preset: preset, saveTo: destination, custom: advanced.spec)
        let selected = Set(selectedItems.map(\.id))
        Task {
            await library.refreshAvailability()
            let items = queueableItems.filter { selected.contains($0.id) }
            guard !items.isEmpty else { return }
            let losses = LossCheck.losses(
                for: items.map { (id: $0.id, source: $0.savingsSource) }, preset: settings.preset,
                custom: settings.custom)
            let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            let lostByURL = Dictionary(
                uniqueKeysWithValues: losses.compactMap { loss in byID[loss.id].map { ($0.url, loss.lost) } })
            if losses.isEmpty {
                enqueue(items, settings: settings, losses: lostByURL)
            } else {
                lossReview = LossReview(
                    entries: losses.compactMap { loss in
                        byID[loss.id].map { .init(id: loss.id, name: $0.url.lastPathComponent, lost: loss.lost) }
                    },
                    items: items, settings: settings, losses: lostByURL)
            }
        }
    }

    /// Convert anyway: adds every reviewed video except the ones marked to skip.
    func confirmLossReview() {
        guard let review = lossReview else { return }
        lossReview = nil
        let skipped = Set(review.entries.filter(\.skip).map(\.id))
        let items = review.items.filter { !skipped.contains($0.id) }
        if !items.isEmpty { enqueue(items, settings: review.settings, losses: review.losses) }
    }

    /// Makes the jobs and adds them; says afterwards what was skipped (already queued, or unreadable).
    private func enqueue(_ items: [LibraryItem], settings: DownscaleJobSettings, losses: [URL: [String]]) {
        let batch = JobFactory.makeJobs(for: items.map(\.url), settings: settings, losses: losses)
        let autoStart = AppSettings.autoStartQueue(defaults)
        if autoStart { isQueuePaused = false }
        send { [weak self] queue in
            let added = await queue.enqueue(batch.jobs)
            if autoStart { await queue.resume() }
            let notice = ActivityText.addNotice(
                alreadyQueued: batch.jobs.count - added.count, unreadable: batch.skipped.count)
            if let notice {
                await MainActor.run { self?.alert = AppAlert(title: "Some videos weren't added", message: notice) }
            }
        }
        notifier.requestAuthorizationOnce()
    }
}
