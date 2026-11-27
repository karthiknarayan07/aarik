import AppCore
import Foundation
import LocalLibrary
import MediaEngine
import PhotosLibrary
import UniformTypeIdentifiers

extension ConvertModel {
    /// The shared queue changed: mirror the originals waiting in Photos, and update the library items a Replace
    /// changed.
    func jobsChanged(_ jobs: [Job]) {
        pendingOriginals = services.pendingDeletions.all
        reconcileReplacedFiles(jobs)
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

    public var queuedJobs: [Job] { jobs.filter(\.state.isPending) }

    /// Videos are waiting and the user hasn't started the run: the Queue offers Start. (Paused mid-run, with a job
    /// still converting, it offers Resume instead.)
    public var waitsForStart: Bool {
        queuePause.isPausedByUser && jobs.contains { $0.state == .queued }
            && !jobs.contains {
                if case .running = $0.state { return true }
                return false
            }
    }

    /// What the waiting videos would save together, from the estimates made when they were added; videos without
    /// one (added by a hand-off, or before estimates were kept) add nothing.
    public var queuedSavingEstimate: Int64 {
        queuedJobs.reduce(into: Int64(0)) { total, job in
            guard ConvertTool.isConvertJob(job.toolID),
                let settings = try? JSONDecoder().decode(ConvertJobSettings.self, from: job.settings)
            else { return }
            total += settings.estimatedSavedBytes ?? 0
        }
    }

    /// Files or images the share sheet or an intent handed over: queued with the current settings, and only queued;
    /// the user starts the run from the Queue (unless Auto-start is on).
    public func queueHandedOff(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let destination = effectiveFileDestination ?? .documents
        let videoSettings = ConvertJobSettings(
            kind: .shrink, preset: preset, saveTo: destination, custom: advanced.spec)
        let imageSettings = ConvertJobSettings(
            kind: .shrink, preset: preset, saveTo: destination, imageSpec: imageAdvanced.spec)
        var videoURLs: [URL] = []
        var imageURLs: [URL] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.contentTypeKey])
            let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
            if let type, type.conforms(to: .image), !type.conforms(to: .movie) {
                imageURLs.append(url)
            } else {
                videoURLs.append(url)
            }
        }
        let jobs =
            (videoURLs.isEmpty ? [] : JobFactory.makeJobs(for: videoURLs, settings: videoSettings).jobs)
            + (imageURLs.isEmpty ? [] : JobFactory.makeJobs(for: imageURLs, settings: imageSettings).jobs)
        guard !jobs.isEmpty else { return }
        let start = takeStartsQueue()
        if start { isQueuePaused = false }
        services.send { queue in
            _ = await queue.enqueue(jobs)
            if start { await queue.resume() }
        }
    }

    // The finished lists show the most recently added first.

    public var completedJobs: [(job: Job, outcome: JobOutcome)] {
        jobs.reversed().compactMap { job in
            if case .completed(let outcome) = job.state { return (job, outcome) }
            return nil
        }
    }

    public var keptAsIsJobs: [(job: Job, reason: String)] {
        jobs.reversed().compactMap { job in
            if case .keptAsIs(let reason, _) = job.state { return (job, reason) }
            return nil
        }
    }

    public var failedJobs: [(job: Job, reason: String)] {
        jobs.reversed().compactMap { job in
            if case .failed(let reason, _) = job.state { return (job, reason) }
            return nil
        }
    }

    // MARK: - Queue commands (the shared queue's)

    public func toggleQueuePaused() { services.toggleQueuePaused() }
    /// The Queue page's Start: works through what waits.
    public func startQueue() { services.startQueue() }
    public func remove(_ job: Job) { services.remove(job) }
    public func cancel(_ job: Job) { services.cancel(job) }
    public func cancelAll() { services.cancelAll() }
    public func retry(_ job: Job) { services.retry(job) }
    public func retryAllFailed() { services.retryAllFailed() }

    /// Finds the loaded Photos or Files item matching `job`, if available in memory.
    public func libraryItem(for job: Job) -> LibraryItem? {
        if let identifier = PhotoAssetURL.identifier(from: job.source) {
            return photos.items.first { $0.photosIdentifier == identifier }
        }
        let target = job.source.standardizedFileURL
        return library.items.first { $0.fileURL?.standardizedFileURL == target }
    }

    /// Updates a waiting (`queued`) job's settings (resolution, bit rate, frame rate, format, save destination) and
    /// optionally swaps the selected video to `replacement`.
    public func updateQueuedJob(
        _ job: Job, existing: ConvertJobSettings, options: AdvancedOptions,
        photosSaveLocation: PhotosSaveLocation, fileSaveLocation: SaveLocation, replacement: LibraryItem? = nil
    ) {
        let resolvedItem = replacement ?? libraryItem(for: job)
        let isPhotos =
            if let replacement {
                replacement.photosIdentifier != nil
            } else {
                ConvertTool.isPhotosJob(job.toolID)
            }
        let custom = options.spec
        var updated = existing
        updated.kind = .shrink
        updated.custom = custom

        if isPhotos {
            guard let destination = photosSaveLocation.destination else { return }
            updated.photosDestination = destination
            updated.saveTo = .nextToOriginal
            if let resolvedItem {
                updated.photosFileName = resolvedItem.name
                let source = resolvedItem.savingsSource
                if case .convert(_, let estimate, _) = SavingsCalculator.decision(
                    byteSize: source.byteSize, inventory: source.inventory, preset: updated.preset, custom: custom)
                {
                    updated.estimatedSavedBytes = max(0, resolvedItem.byteSize - estimate)
                } else {
                    updated.estimatedSavedBytes = nil
                }
                updated.predictedLost = PhotosLossCheck.lostNames(
                    isCinematic: resolvedItem.badges.contains(.cinematic),
                    isHDR: resolvedItem.badges.contains(.hdr) || resolvedItem.badges.contains(.dolbyVision),
                    custom: custom)
                updated.predictedLostKeys = nil
            }
        } else {
            guard let destination = fileSaveLocation.destination else { return }
            updated.saveTo = destination
            updated.photosDestination = nil
            updated.photosFileName = nil
            if let resolvedItem {
                let source = resolvedItem.savingsSource
                if case .convert(_, let estimate, _) = SavingsCalculator.decision(
                    byteSize: source.byteSize, inventory: source.inventory, preset: updated.preset, custom: custom)
                {
                    updated.estimatedSavedBytes = max(0, resolvedItem.byteSize - estimate)
                } else {
                    updated.estimatedSavedBytes = nil
                }
                let lost = LossCheck.losses(
                    for: [(id: resolvedItem.id, source: source, preset: updated.preset)], custom: custom
                ).first
                updated.predictedLost = lost?.lost ?? []
                updated.predictedLostKeys = lost?.keys ?? []
            }
        }

        var newToolID = job.toolID
        var newSource = job.source
        var newBookmark = job.sourceBookmark
        if let replacement {
            let isImage = replacement.isImage
            if let identifier = replacement.photosIdentifier {
                newToolID = isImage ? ConvertTool.imagePhotosToolID : ConvertTool.photosToolID
                newSource = PhotoAssetURL.url(for: identifier)
                newBookmark = Data()
            } else if let url = replacement.fileURL,
                let created = JobFactory.makeJobs(for: [url], settings: updated).jobs.first
            {
                newToolID = isImage ? ConvertTool.imageToolID : ConvertTool.toolID
                newSource = created.source
                newBookmark = created.sourceBookmark
            } else {
                return
            }
        }

        guard let encoded = try? JSONEncoder().encode(updated) else { return }
        services.send { [newToolID, newSource, newBookmark] queue in
            await queue.updateQueued(id: job.id) { item in
                item.toolID = newToolID
                item.source = newSource
                item.sourceBookmark = newBookmark
                item.settings = encoded
            }
        }
    }

    /// Updates a waiting (`queued`) image job's conversion settings and optionally swaps its source to `replacement`.
    public func updateQueuedImageJob(
        _ job: Job, existing: ConvertJobSettings, options: ImageAdvancedOptions,
        photosSaveLocation: PhotosSaveLocation, fileSaveLocation: SaveLocation, replacement: LibraryItem? = nil
    ) {
        let resolvedItem = replacement ?? libraryItem(for: job)
        let isPhotos =
            if let replacement {
                replacement.photosIdentifier != nil
            } else {
                ConvertTool.isPhotosJob(job.toolID)
            }
        let spec = options.spec
        var updated = existing
        updated.kind = .shrink
        updated.custom = nil
        updated.imageSpec = spec

        if isPhotos {
            guard let destination = photosSaveLocation.destination else { return }
            updated.photosDestination = destination
            updated.saveTo = .nextToOriginal
            if let resolvedItem {
                updated.photosFileName = resolvedItem.name
                let freed = OverviewSummary.couldFree(
                    resolvedItem, preset: updated.preset, custom: nil, imageSpec: spec)
                updated.estimatedSavedBytes = freed > 0 ? freed : nil
                updated.predictedLost = ImageLossCheck.photosLostNames(
                    isRAW: resolvedItem.badges.contains(.raw),
                    hasDepth: resolvedItem.badges.contains(.portrait),
                    hasHDR: resolvedItem.badges.contains(.hdr),
                    isLivePhoto: resolvedItem.badges.contains(.livePhoto),
                    hasAlpha: resolvedItem.badges.contains(.transparent),
                    isAnimated: resolvedItem.badges.contains(.animated),
                    sourceUTI: resolvedItem.imageSourceUTI,
                    spec: spec)
                updated.predictedLostKeys = nil
            }
        } else {
            guard let destination = fileSaveLocation.destination else { return }
            updated.saveTo = destination
            updated.photosDestination = nil
            updated.photosFileName = nil
            if let resolvedItem {
                let freed = OverviewSummary.couldFree(
                    resolvedItem, preset: updated.preset, custom: nil, imageSpec: spec)
                updated.estimatedSavedBytes = freed > 0 ? freed : nil
                let loss = ImageLossCheck.losses(
                    for: [
                        (
                            id: resolvedItem.id, sourceUTI: resolvedItem.imageSourceUTI,
                            byteSize: resolvedItem.byteSize, pixelSize: resolvedItem.pixelSize,
                            inventory: resolvedItem.inventory, isLivePhoto: resolvedItem.badges.contains(.livePhoto)
                        )
                    ],
                    spec: spec
                ).first
                updated.predictedLost = loss?.lost ?? []
                updated.predictedLostKeys = loss?.keys ?? []
            }
        }

        var newToolID = job.toolID
        var newSource = job.source
        var newBookmark = job.sourceBookmark
        if let replacement {
            let isImage = replacement.isImage
            if let identifier = replacement.photosIdentifier {
                newToolID = isImage ? ConvertTool.imagePhotosToolID : ConvertTool.photosToolID
                newSource = PhotoAssetURL.url(for: identifier)
                newBookmark = Data()
            } else if let url = replacement.fileURL,
                let created = JobFactory.makeJobs(for: [url], settings: updated).jobs.first
            {
                newToolID = isImage ? ConvertTool.imageToolID : ConvertTool.toolID
                newSource = created.source
                newBookmark = created.sourceBookmark
            } else {
                return
            }
        }

        guard let encoded = try? JSONEncoder().encode(updated) else { return }
        services.send { [newToolID, newSource, newBookmark] queue in
            await queue.updateQueued(id: job.id) { item in
                item.toolID = newToolID
                item.source = newSource
                item.sourceBookmark = newBookmark
                item.settings = encoded
            }
        }
    }
}
