import AppCore
import AppUI
import Foundation
import LocalLibrary

/// Videos that would lose metadata, each with what it loses and whether the user chose to skip it.
public struct LossReview {
    public struct Entry: Identifiable {
        public let id: UUID
        public let name: String
        public let lost: [String]
        public var skip = false
    }

    public var entries: [Entry]
    /// Every video to add, lossy or not, in grid order.
    public let items: [LibraryItem]
    public let settings: ConvertJobSettings
    /// Each video's preset when it was added (the header's, or its own from the inspector).
    public let presets: [UUID: Preset]
    /// What each lossy file loses, for the jobs' badges and the runner's check.
    public let losses: [URL: PredictedLoss<UUID>]
    /// Selected videos found missing just before they would have been added.
    public let missing: Int
    /// Set for Photos videos: where their copies go and what each is predicted to lose.
    public var photos: PhotosBatch?
}

/// What a batch of Photos videos is added with.
public struct PhotosBatch {
    public let destination: PhotosDestination
    /// Predicted losses by Photos local identifier, for the jobs' badges and the runner's check.
    public let lost: [String: [String]]
}

extension ConvertModel {
    /// Available selected items; missing files can't be converted.
    public var queueableItems: [LibraryItem] { selectedItems.filter { $0.isAvailable && $0.fileURL != nil } }

    public var canAddSelectionToQueue: Bool {
        if isPhotosPage { return canAddPhotosToQueue }
        return !queueableItems.isEmpty && effectiveFileDestination != nil
    }

    /// File destination with platform policy enforced (Replace is disabled for Files inputs on iOS).
    public var effectiveFileDestination: SaveDestination? {
        guard let destination = saveLocation.destination else { return nil }
        if !SaveLocation.allowsReplace(), destination == .replace {
            return SaveLocation(platform: .current).destination
        }
        return destination
    }

    public var addToQueueTitle: String {
        let items = queueableItems
        return QueueButtonTitle.title(
            count: items.count, preset: items.first.map(effectivePreset(for:)) ?? preset,
            isCustom: advanced.isEnabled)
    }

    /// Opens the Compress picker sheet for the current selection.
    public func presentCompress() {
        guard canAddSelectionToQueue else { return }
        isCompressPresented = true
    }

    /// Confirms the Compress sheet and queues the selection with the chosen compression preset.
    public func confirmCompress() {
        isCompressPresented = false
        requestAddSelectionToQueue(kind: .compress(compressPreset))
    }

    /// Asks for confirmation before the first Replace of the session, otherwise adds right away.
    public func requestAddSelectionToQueue(kind: ConvertJobKind = .shrink) {
        guard canAddSelectionToQueue else { return }
        let replaces =
            isPhotosPage ? photosSaveLocation.choice == .replace : effectiveFileDestination == .replace
        if replaces, replaceConsent.needsAsking {
            pendingReplaceKind = kind
            isConfirmingReplace = true
        } else if isPhotosPage {
            addPhotosSelectionToQueue(kind: kind)
        } else {
            addSelectionToQueue(kind: kind)
        }
    }

    /// The confirmation holds only once videos are added: cancelling the loss sheet asks again next time.
    public func confirmReplace() {
        let kind = pendingReplaceKind
        pendingReplaceKind = .shrink
        replaceConsent.confirm()
        if isPhotosPage { addPhotosSelectionToQueue(kind: kind) } else { addSelectionToQueue(kind: kind) }
    }

    /// Re-checks which files are still there, then adds one job per available selected video with its preset
    /// (its own, else the header's), the Advanced spec and the Save to choice. Videos that would lose metadata (in the conversion, or because an
    /// MPEG-4 file has to be saved as QuickTime) are listed for the user first (`lossReview`); the rest go
    /// straight in.
    public func addSelectionToQueue(kind: ConvertJobKind = .shrink) {
        guard let destination = effectiveFileDestination else {
            replaceConsent.abandon()
            return
        }
        let custom = kind == .shrink ? advanced.spec : nil
        let settings = ConvertJobSettings(kind: kind, preset: preset, saveTo: destination, custom: custom)
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
                kind: kind, custom: settings.custom, quickTimeFallbacks: fallbacks)
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
    public func confirmLossReview() {
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
    public func cancelLossReview() {
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
                item.fileURL.map {
                    (url: $0, preset: presets[item.id] ?? settings.preset, bookmark: library.bookmark(for: item.id))
                }
            }, settings: settings,
            losses: losses)
        let autoStart = services.settings.autoStartQueue
        if autoStart { isQueuePaused = false }
        services.send { [weak self] queue in
            let added = await queue.enqueue(batch.jobs)
            if autoStart { await queue.resume() }
            let alreadyQueued = batch.jobs.count - added.count
            await MainActor.run {
                self?.showAddNotice(alreadyQueued: alreadyQueued, unreadable: batch.skipped.count, missing: missing)
            }
        }
        host.requestNotificationAuthorization()
    }

    public func showAddNotice(alreadyQueued: Int, unreadable: Int, missing: Int) {
        guard
            let notice = ActivityText.addNotice(alreadyQueued: alreadyQueued, unreadable: unreadable, missing: missing)
        else { return }
        alert = AppAlert(title: "Some Videos Weren't Added", message: notice)
    }
}
