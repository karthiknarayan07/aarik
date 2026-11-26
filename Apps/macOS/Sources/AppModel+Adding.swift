import AppCore
import AppUI
import Convert
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
    let settings: ConvertJobSettings
    /// Each video's preset when it was added (the header's, or its own from the inspector).
    let presets: [UUID: Preset]
    /// What each lossy file loses, for the jobs' badges and the runner's check.
    let losses: [URL: PredictedLoss<UUID>]
    /// Selected videos found missing just before they would have been added.
    let missing: Int
    /// Set for Photos videos: where their copies go and what each is predicted to lose.
    var photos: PhotosBatch?
}

/// What a batch of Photos videos is added with.
struct PhotosBatch {
    let destination: PhotosDestination
    /// Predicted losses by Photos local identifier, for the jobs' badges and the runner's check.
    let lost: [String: [String]]
}

extension AppModel {
    /// Available selected items; missing files can't be converted.
    var queueableItems: [LibraryItem] { selectedItems.filter { $0.isAvailable && $0.fileURL != nil } }

    var canAddSelectionToQueue: Bool {
        if isPhotosPage { return canAddPhotosToQueue }
        return !queueableItems.isEmpty && saveLocation.destination != nil
    }

    var addToQueueTitle: String {
        let items = queueableItems
        return QueueButtonTitle.title(
            count: items.count, preset: items.first.map(effectivePreset(for:)) ?? preset,
            isCustom: advanced.isEnabled)
    }

    /// Asks for confirmation before the first Replace of the session, otherwise adds right away.
    func requestAddSelectionToQueue() {
        guard canAddSelectionToQueue else { return }
        let replaces = isPhotosPage ? photosSaveLocation.choice == .replace : saveLocation.choice == .replace
        if replaces, replaceConsent.needsAsking {
            isConfirmingReplace = true
        } else if isPhotosPage {
            addPhotosSelectionToQueue()
        } else {
            addSelectionToQueue()
        }
    }

    /// The confirmation holds only once videos are added: cancelling the loss sheet asks again next time.
    func confirmReplace() {
        replaceConsent.confirm()
        if isPhotosPage { addPhotosSelectionToQueue() } else { addSelectionToQueue() }
    }

    /// Re-checks which files are still there, then adds one job per available selected video with its preset
    /// (its own, else the header's), the Advanced spec and the Save to choice. Videos that would lose metadata (in the conversion, or because an
    /// MPEG-4 file has to be saved as QuickTime) are listed for the user first (`lossReview`); the rest go
    /// straight in.
    func addSelectionToQueue() {
        guard let destination = saveLocation.destination else {
            replaceConsent.abandon()
            return
        }
        let settings = ConvertJobSettings(preset: preset, saveTo: destination, custom: advanced.spec)
        let presets = Dictionary(uniqueKeysWithValues: selectedItems.map { ($0.id, effectivePreset(for: $0)) })
        let selected = Set(selectedItems.map(\.id))
        let wasAvailable = Set(queueableItems.map(\.id))
        Task {
            await library.refreshAvailability()
            let items = queueableItems.filter { selected.contains($0.id) }
            let missing = library.items.count(where: { wasAvailable.contains($0.id) && !$0.isAvailable })
            guard !items.isEmpty else {
                replaceConsent.abandon()
                showAddNotice(alreadyQueued: 0, unreadable: 0, missing: missing)
                return
            }
            let fallbacks = await LossCheck.quickTimeFallbacks(
                among: items.compactMap { item in item.fileURL.map { (id: item.id, url: $0) } })
            let losses = LossCheck.losses(
                for: items.map { (id: $0.id, source: $0.savingsSource, preset: presets[$0.id] ?? settings.preset) },
                custom: settings.custom, quickTimeFallbacks: fallbacks)
            let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            let lostByURL = Dictionary(
                uniqueKeysWithValues: losses.compactMap { loss in
                    byID[loss.id].flatMap { $0.fileURL }.map { ($0, loss) }
                })
            if losses.isEmpty {
                enqueue(items, settings: settings, presets: presets, losses: lostByURL, missing: missing)
            } else {
                lossReview = LossReview(
                    entries: losses.compactMap { loss in
                        byID[loss.id].map { .init(id: loss.id, name: $0.name, lost: loss.lost) }
                    },
                    items: items, settings: settings, presets: presets, losses: lostByURL, missing: missing)
            }
        }
    }

    /// Convert anyway: adds every reviewed video except the ones marked to skip.
    func confirmLossReview() {
        guard let review = lossReview else { return }
        lossReview = nil
        let skipped = Set(review.entries.filter(\.skip).map(\.id))
        let items = review.items.filter { !skipped.contains($0.id) }
        if let photos = review.photos {
            if !items.isEmpty {
                enqueuePhotos(items, settings: review.settings, presets: review.presets, batch: photos)
            }
        } else if items.isEmpty {
            replaceConsent.abandon()
        } else {
            enqueue(
                items, settings: review.settings, presets: review.presets, losses: review.losses,
                missing: review.missing)
        }
    }

    /// Cancel on the loss sheet: nothing is added, and a Replace confirmed just before doesn't count.
    func cancelLossReview() {
        guard lossReview != nil else { return }
        lossReview = nil
        replaceConsent.abandon()
    }

    /// Makes the jobs and adds them; says afterwards what was skipped (already queued, unreadable, or found
    /// missing just before).
    private func enqueue(
        _ items: [LibraryItem], settings: ConvertJobSettings, presets: [UUID: Preset],
        losses: [URL: PredictedLoss<UUID>], missing: Int
    ) {
        replaceConsent.videosAdded()
        let batch = JobFactory.makeJobs(
            for: items.compactMap { item in
                item.fileURL.map { (url: $0, preset: presets[item.id] ?? settings.preset) }
            }, settings: settings,
            losses: losses)
        let autoStart = AppSettings.autoStartQueue(defaults)
        if autoStart { isQueuePaused = false }
        send { [weak self] queue in
            let added = await queue.enqueue(batch.jobs)
            if autoStart { await queue.resume() }
            let alreadyQueued = batch.jobs.count - added.count
            await MainActor.run {
                self?.showAddNotice(alreadyQueued: alreadyQueued, unreadable: batch.skipped.count, missing: missing)
            }
        }
        notifier.requestAuthorizationOnce()
    }

    func showAddNotice(alreadyQueued: Int, unreadable: Int, missing: Int) {
        guard
            let notice = ActivityText.addNotice(alreadyQueued: alreadyQueued, unreadable: unreadable, missing: missing)
        else { return }
        alert = AppAlert(title: "Some videos weren't added", message: notice)
    }
}
