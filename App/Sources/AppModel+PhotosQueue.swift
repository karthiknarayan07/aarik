import AppCore
import AppUI
import DownscaleVideo
import Foundation
import LocalLibrary
import PhotosLibrary

/// Where the Videos page puts converted copies: a new video in Photos, a new video with the original moved to
/// Recently Deleted afterwards, or a folder on this Mac.
struct PhotosSaveLocation: Equatable {
    enum Choice: String, CaseIterable, Identifiable {
        case newAsset, replace, folder

        var id: Self { self }
        var title: String {
            switch self {
            case .newAsset: "Photos, as a new video"
            case .replace: "Replace Original in Photos"
            case .folder: "Folder…"
            }
        }
    }

    var choice = Choice.newAsset
    var folder: URL?
    var folderBookmark: Data?

    /// What a job records; nil while Folder is chosen but no folder has been picked.
    var destination: PhotosDestination? {
        switch choice {
        case .newAsset: .newAsset
        case .replace: .replace
        case .folder: folderBookmark.map { .folder(bookmark: $0) }
        }
    }

    /// Remembers a picked folder as a bookmark (security-scoped when the system allows it).
    mutating func setFolder(_ url: URL) throws {
        let bookmark: Data
        if let scoped = try? url.bookmarkData(options: [.withSecurityScope]) {
            bookmark = scoped
        } else {
            bookmark = try url.bookmarkData(options: [])
        }
        folder = url
        folderBookmark = bookmark
        choice = .folder
    }
}

extension AppModel {
    /// The inspector's preset for the selected Photos videos: the one they share, nil when they differ ("Mixed").
    /// Choosing one gives it to every selected video, leaving the header's preset alone.
    var photoSelectionPreset: Preset? {
        get { presetOverrides.selectionPreset(for: selectedPhotoItems.map(\.id), default: preset) }
        set {
            guard let newValue else { return }
            presetOverrides.set(newValue, for: selectedPhotoItems.map(\.id), default: preset)
        }
    }

    var canAddPhotosToQueue: Bool {
        !selectedPhotoItems.isEmpty && photosSaveLocation.destination != nil
    }

    var addPhotosToQueueTitle: String {
        let items = selectedPhotoItems
        return QueueButtonTitle.title(
            count: items.count, preset: items.first.map(effectivePreset(for:)) ?? preset, isCustom: false)
    }

    /// Adds the selected Photos videos. Nothing is downloaded now: each video is fetched when its turn comes.
    /// Videos Photos says will lose something (Cinematic depth data) are listed for the user first.
    func addPhotosSelectionToQueue() {
        guard let destination = photosSaveLocation.destination else { return }
        // The Advanced options are not offered for Photos videos yet, so a hidden custom spec never applies.
        let settings = DownscaleJobSettings(preset: preset, saveTo: .nextToOriginal)
        let items = selectedPhotoItems
        let presets = Dictionary(uniqueKeysWithValues: items.map { ($0.id, effectivePreset(for: $0)) })
        var lost: [String: [String]] = [:]
        for item in items {
            guard let identifier = item.photosIdentifier else { continue }
            lost[identifier] = PhotosLossCheck.lostNames(
                isCinematic: item.badges.contains(.cinematic),
                isHDR: item.badges.contains(.hdr) || item.badges.contains(.dolbyVision), custom: settings.custom)
        }
        let batch = PhotosBatch(destination: destination, lost: lost)
        let losing = items.compactMap { item -> LossReview.Entry? in
            guard let identifier = item.photosIdentifier, let names = lost[identifier], !names.isEmpty else {
                return nil
            }
            return .init(id: item.id, name: item.name, lost: names)
        }
        if losing.isEmpty {
            enqueuePhotos(items, settings: settings, presets: presets, batch: batch)
        } else {
            lossReview = LossReview(
                entries: losing, items: items, settings: settings, presets: presets, losses: [:], missing: 0,
                photos: batch)
        }
    }

    /// Context menu: Add to queue, for the selection or the clicked tile.
    func addPhotosToQueue(clicked item: LibraryItem) {
        if !selectedPhotoItems.contains(where: { $0.id == item.id }) { photosBrowser.selection = [item.id] }
        requestAddSelectionToQueue()
    }

    func enqueuePhotos(
        _ items: [LibraryItem], settings: DownscaleJobSettings, presets: [UUID: Preset], batch: PhotosBatch
    ) {
        replaceConsent.videosAdded()
        let jobs = PhotosJobFactory.makeJobs(
            for: items.compactMap { item in
                item.photosIdentifier.map {
                    (assetID: $0, name: item.name, preset: presets[item.id] ?? settings.preset)
                }
            }, settings: settings, destination: batch.destination, lost: batch.lost)
        let autoStart = AppSettings.autoStartQueue(defaults)
        if autoStart { isQueuePaused = false }
        send { [weak self] queue in
            let added = await queue.enqueue(jobs)
            if autoStart { await queue.resume() }
            let alreadyQueued = jobs.count - added.count
            await MainActor.run {
                self?.showAddNotice(alreadyQueued: alreadyQueued, unreadable: 0, missing: 0)
            }
        }
        notifier.requestAuthorizationOnce()
    }
}
