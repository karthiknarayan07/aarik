import AppCore
import AppUI
import Foundation
import LocalLibrary
import MediaEngine

/// Videos that would lose metadata, each with what it loses and whether the user chose to skip it.
public struct LossReview: Identifiable {
    public let id = UUID()
    public struct Entry: Identifiable {
        public let id: UUID
        public let name: String
        public let lost: [String]
        public var skip = false
    }

    public var entries: [Entry]
    /// Every video or image to add, lossy or not, in grid order.
    public let items: [LibraryItem]
    public let settings: ConvertJobSettings
    /// Optional image settings when a batch includes image files or Photos images.
    public let imageSettings: ConvertJobSettings?
    /// Each video's preset when it was added (the header's, or its own from the inspector).
    public let presets: [UUID: Preset]
    /// What each lossy file loses, for the jobs' badges and the runner's check.
    public let losses: [URL: PredictedLoss<UUID>]
    /// Selected files found missing just before they would have been added.
    public let missing: Int
    /// Set for Photos items: where their copies go and what each is predicted to lose.
    public var photos: PhotosBatch?

    public init(
        entries: [Entry], items: [LibraryItem], settings: ConvertJobSettings,
        imageSettings: ConvertJobSettings? = nil, presets: [UUID: Preset], losses: [URL: PredictedLoss<UUID>],
        missing: Int, photos: PhotosBatch? = nil
    ) {
        self.entries = entries
        self.items = items
        self.settings = settings
        self.imageSettings = imageSettings
        self.presets = presets
        self.losses = losses
        self.missing = missing
        self.photos = photos
    }
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
        if !items.isEmpty, items.allSatisfy(\.isImage) {
            if items.count == 1 { return "Add to queue · \(imageAdvanced.resolution.title)" }
            return "Add \(items.count) to queue"
        }
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

    /// Convert Now: adds the selection and starts the queue, whatever the Auto-start setting says.
    public func convertSelectionNow() {
        requestAddSelectionToQueue(startsQueue: true)
    }

    /// Asks for confirmation before the first Replace of the session, otherwise adds right away. `startsQueue`
    /// says whether the queue starts with the add; nil follows the Auto-start setting (on for the Mac, off on iOS).
    public func requestAddSelectionToQueue(kind: ConvertJobKind = .shrink, startsQueue: Bool? = nil) {
        guard canAddSelectionToQueue else { return }
        addStartsQueue = startsQueue
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
    /// (its own, else the header's), the Advanced spec and the Save To choice. Videos that would lose metadata (in the conversion, or because an
    /// MPEG-4 file has to be saved as QuickTime) are listed for the user first (`lossReview`); the rest go
    /// straight in.
    public func addSelectionToQueue(kind: ConvertJobKind = .shrink) {
        guard let destination = effectiveFileDestination else {
            replaceConsent.abandon()
            return
        }
        let custom = kind == .shrink ? advanced.spec : nil
        let settings = ConvertJobSettings(kind: kind, preset: preset, saveTo: destination, custom: custom)
        let imgSpec = imageAdvanced.spec
        let imageSettings = ConvertJobSettings(
            kind: .shrink, preset: preset, saveTo: destination, imageSpec: imgSpec)
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
            let videoItems = items.filter { !$0.isImage }
            let imageItems = items.filter(\.isImage)
            let fallbacks =
                videoItems.isEmpty
                ? Set<UUID>()
                : await LossCheck.quickTimeFallbacks(
                    among: videoItems.compactMap { item in item.fileURL.map { (id: item.id, url: $0) } })
            let videoLosses = LossCheck.losses(
                for: videoItems.map {
                    (id: $0.id, source: $0.savingsSource, preset: presets[$0.id] ?? settings.preset)
                },
                kind: kind, custom: settings.custom, quickTimeFallbacks: fallbacks)
            let imageLosses = ImageLossCheck.losses(
                for: imageItems.map {
                    (
                        id: $0.id, sourceUTI: $0.imageSourceUTI, byteSize: $0.byteSize, pixelSize: $0.pixelSize,
                        inventory: $0.inventory, isLivePhoto: $0.badges.contains(.livePhoto)
                    )
                }, spec: imgSpec)
            let losses = videoLosses + imageLosses
            let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            let lostByURL = Dictionary(
                uniqueKeysWithValues: losses.compactMap { loss in
                    byID[loss.id].flatMap { $0.fileURL }.map { ($0, loss) }
                })
            if losses.isEmpty {
                enqueue(
                    items, settings: settings, imageSettings: imageItems.isEmpty ? nil : imageSettings,
                    presets: presets, losses: lostByURL, missing: missing)
            } else {
                lossReview = LossReview(
                    entries: losses.compactMap { loss in
                        byID[loss.id].map { .init(id: loss.id, name: $0.name, lost: loss.lost) }
                    },
                    items: items, settings: settings, imageSettings: imageItems.isEmpty ? nil : imageSettings,
                    presets: presets, losses: lostByURL, missing: missing)
            }
        }
    }

    /// Convert anyway: adds every reviewed item except the ones marked to skip.
    public func confirmLossReview() {
        guard let review = lossReview else { return }
        lossReview = nil
        let skipped = Set(review.entries.filter(\.skip).map(\.id))
        let items = review.items.filter { !skipped.contains($0.id) }
        if let photos = review.photos {
            if !items.isEmpty {
                enqueuePhotos(
                    items, settings: review.settings, imageSettings: review.imageSettings, presets: review.presets,
                    batch: photos)
            }
        } else if items.isEmpty {
            replaceConsent.abandon()
        } else {
            enqueue(
                items, settings: review.settings, imageSettings: review.imageSettings, presets: review.presets,
                losses: review.losses, missing: review.missing)
        }
    }

    /// Cancel on the loss sheet: nothing is added, and a Replace confirmed just before doesn't count.
    public func cancelLossReview() {
        guard lossReview != nil else { return }
        lossReview = nil
        addStartsQueue = nil
        replaceConsent.abandon()
    }

    /// Makes the jobs and adds them; says afterwards what was skipped (already queued, unreadable, or found
    /// missing just before).
    private func enqueue(
        _ items: [LibraryItem], settings: ConvertJobSettings, imageSettings: ConvertJobSettings? = nil,
        presets: [UUID: Preset], losses: [URL: PredictedLoss<UUID>], missing: Int
    ) {
        replaceConsent.videosAdded()
        let effectiveImageSettings =
            imageSettings
            ?? ConvertJobSettings(
                kind: .shrink, preset: settings.preset, saveTo: settings.saveTo, imageSpec: imageAdvanced.spec)
        let savings = estimatedSavings(
            for: items, settings: settings, imageSpec: effectiveImageSettings.imageSpec ?? imageAdvanced.spec,
            presets: presets)
        let videoItems = items.filter { !$0.isImage }
        let imageItems = items.filter(\.isImage)
        func batch(for subset: [LibraryItem], using itemSettings: ConvertJobSettings) -> JobBatch {
            guard !subset.isEmpty else { return JobBatch(jobs: [], skipped: []) }
            return JobFactory.makeJobs(
                for: subset.compactMap { item in
                    item.fileURL.map {
                        (
                            url: $0, preset: presets[item.id] ?? itemSettings.preset,
                            bookmark: library.bookmark(for: item.id)
                        )
                    }
                },
                settings: itemSettings,
                losses: losses,
                savings: Dictionary(
                    subset.compactMap { item in item.fileURL.flatMap { url in savings[item.id].map { (url, $0) } } },
                    uniquingKeysWith: { first, _ in first }))
        }
        let videoBatch = batch(for: videoItems, using: settings)
        let imageBatch = batch(for: imageItems, using: effectiveImageSettings)
        let combinedJobs = videoBatch.jobs + imageBatch.jobs
        let combinedSkipped = videoBatch.skipped + imageBatch.skipped
        let start = takeStartsQueue()
        if start { isQueuePaused = false }
        services.send { [weak self] queue in
            let added = await queue.enqueue(combinedJobs)
            if start { await queue.resume() }
            let alreadyQueued = combinedJobs.count - added.count
            await MainActor.run {
                self?.showAddNotice(alreadyQueued: alreadyQueued, unreadable: combinedSkipped.count, missing: missing)
            }
        }
        host.requestNotificationAuthorization()
    }

    /// Whether this add starts the queue (Convert Now, or the Auto-start setting when the add didn't say); each
    /// add decides once.
    func takeStartsQueue() -> Bool {
        defer { addStartsQueue = nil }
        return addStartsQueue ?? services.settings.autoStartQueue
    }

    /// What converting each video or image would save with its settings, by library item id; items that would be
    /// kept as they are have none.
    func estimatedSavings(
        for items: [LibraryItem], settings: ConvertJobSettings, imageSpec: ImageSpec? = nil, presets: [UUID: Preset]
    ) -> [UUID: Int64] {
        var result: [UUID: Int64] = [:]
        let resolvedImageSpec = imageSpec ?? settings.imageSpec ?? imageAdvanced.spec
        for item in items {
            if item.isImage {
                let freed = OverviewSummary.couldFree(
                    item, preset: settings.preset, custom: nil, imageSpec: resolvedImageSpec)
                if freed > 0 { result[item.id] = freed }
                continue
            }
            let freed: Int64
            switch settings.kind {
            case .shrink:
                freed = SavingsCalculator.couldFreeBytes(
                    for: [(source: item.savingsSource, preset: presets[item.id] ?? settings.preset)],
                    custom: settings.custom)
            case .compress(let compressPreset):
                freed = SavingsCalculator.couldFreeBytes(for: [item.savingsSource], compressPreset: compressPreset)
            }
            if freed > 0 { result[item.id] = freed }
        }
        return result
    }

    public func showAddNotice(alreadyQueued: Int, unreadable: Int, missing: Int) {
        guard
            let notice = ActivityText.addNotice(alreadyQueued: alreadyQueued, unreadable: unreadable, missing: missing)
        else { return }
        alert = AppAlert(title: "Some Items Weren't Added", message: notice)
    }
}
