import AppCore
import AppUI
import Foundation
import LocalLibrary
import PhotosLibrary

/// Where the Videos page puts converted copies: a new video in Photos, a new video with the original moved to
/// Recently Deleted afterwards, or a folder on this Mac.
public struct PhotosSaveLocation: Equatable {
    public enum Choice: String, CaseIterable, Identifiable {
        case newAsset, replace, folder

        public var id: Self { self }
        public var title: String {
            switch self {
            case .newAsset: "Photos, as a New Video"
            case .replace: "Replace Original in Photos"
            case .folder: "Folder…"
            }
        }
    }

    public var choice = Choice.newAsset
    public var folder: URL?
    public var folderBookmark: Data?

    public init() {}

    public init(destination: PhotosDestination?) {
        switch destination {
        case .newAsset, nil: self.choice = .newAsset
        case .replace: self.choice = .replace
        case .folder(let bookmark):
            self.choice = .folder
            self.folderBookmark = bookmark
            self.folder = AppSettings.resolve(bookmark)
        }
    }

    /// What a job records; nil while Folder is chosen but no folder has been picked.
    public var destination: PhotosDestination? {
        switch choice {
        case .newAsset: .newAsset
        case .replace: .replace
        case .folder: folderBookmark.map { .folder(bookmark: $0) }
        }
    }

    /// Remembers a picked folder as a bookmark (security-scoped when the system allows it).
    public mutating func setFolder(_ url: URL) throws {
        let bookmark: Data
        if !PlatformBookmark.creation.isEmpty, let scoped = try? url.bookmarkData(options: PlatformBookmark.creation) {
            bookmark = scoped
        } else {
            bookmark = try url.bookmarkData(options: [])
        }
        folder = url
        folderBookmark = bookmark
        choice = .folder
    }
}

extension ConvertModel {
    /// The inspector's preset for the selected Photos videos: the one they share, nil when they differ ("Mixed").
    /// Choosing one gives it to every selected video, leaving the header's preset alone.
    public var photoSelectionPreset: Preset? {
        get { presetOverrides.selectionPreset(for: selectedPhotoItems.map(\.id), default: preset) }
        set {
            guard let newValue else { return }
            presetOverrides.set(newValue, for: selectedPhotoItems.map(\.id), default: preset)
        }
    }

    public var canAddPhotosToQueue: Bool {
        !selectedPhotoItems.isEmpty && photosSaveLocation.destination != nil
    }

    public var addPhotosToQueueTitle: String {
        let items = selectedPhotoItems
        if !items.isEmpty, items.allSatisfy(\.isImage) {
            if items.count == 1 { return "Add to queue · \(imageAdvanced.resolution.title)" }
            return "Add \(items.count) to queue"
        }
        return QueueButtonTitle.title(
            count: items.count, preset: items.first.map(effectivePreset(for:)) ?? preset, isCustom: false)
    }

    /// Adds the selected Photos videos and images. Nothing is downloaded now: each item is fetched when its turn comes.
    /// Items Photos says will lose something (Cinematic depth, RAW data, Live Photo motion) are listed first.
    public func addPhotosSelectionToQueue(kind: ConvertJobKind = .shrink) {
        guard let destination = photosSaveLocation.destination else { return }
        let settings = ConvertJobSettings(
            kind: kind, preset: preset, saveTo: .nextToOriginal, custom: kind == .shrink ? advanced.spec : nil)
        let imgSpec = imageAdvanced.spec
        let imageSettings = ConvertJobSettings(
            kind: .shrink, preset: preset, saveTo: .nextToOriginal, imageSpec: imgSpec)
        let items = selectedPhotoItems
        let presets = Dictionary(uniqueKeysWithValues: items.map { ($0.id, effectivePreset(for: $0)) })
        var lost: [String: [String]] = [:]
        for item in items {
            guard let identifier = item.photosIdentifier else { continue }
            if item.isImage {
                lost[identifier] = ImageLossCheck.photosLostNames(
                    isRAW: item.badges.contains(.raw),
                    hasDepth: item.badges.contains(.portrait),
                    hasHDR: item.badges.contains(.hdr),
                    isLivePhoto: item.badges.contains(.livePhoto),
                    hasAlpha: item.badges.contains(.transparent),
                    isAnimated: item.badges.contains(.animated),
                    sourceUTI: item.imageSourceUTI,
                    spec: imgSpec)
            } else {
                lost[identifier] = PhotosLossCheck.lostNames(
                    isCinematic: item.badges.contains(.cinematic),
                    isHDR: item.badges.contains(.hdr) || item.badges.contains(.dolbyVision), custom: settings.custom)
            }
        }
        let batch = PhotosBatch(destination: destination, lost: lost)
        let losing = items.compactMap { item -> LossReview.Entry? in
            guard let identifier = item.photosIdentifier, let names = lost[identifier], !names.isEmpty else {
                return nil
            }
            return .init(id: item.id, name: item.name, lost: names)
        }
        let hasImages = items.contains(where: \.isImage)
        if losing.isEmpty {
            enqueuePhotos(
                items, settings: settings, imageSettings: hasImages ? imageSettings : nil, presets: presets,
                batch: batch)
        } else {
            lossReview = LossReview(
                entries: losing, items: items, settings: settings,
                imageSettings: hasImages ? imageSettings : nil, presets: presets, losses: [:], missing: 0,
                photos: batch)
        }
    }

    /// Context menu: Add to queue, for the selection or the clicked tile.
    public func addPhotosToQueue(clicked item: LibraryItem) {
        if !selectedPhotoItems.contains(where: { $0.id == item.id }) { photosBrowser.selection = [item.id] }
        requestAddSelectionToQueue()
    }

    /// Context menu: Compress…, for the selection or the clicked tile.
    public func compressPhotosClicked(_ item: LibraryItem) {
        if !selectedPhotoItems.contains(where: { $0.id == item.id }) { photosBrowser.selection = [item.id] }
        presentCompress()
    }

    public func enqueuePhotos(
        _ items: [LibraryItem], settings: ConvertJobSettings, imageSettings: ConvertJobSettings? = nil,
        presets: [UUID: Preset], batch: PhotosBatch
    ) {
        replaceConsent.videosAdded()
        let effectiveImageSettings =
            imageSettings
            ?? ConvertJobSettings(
                kind: .shrink, preset: settings.preset, saveTo: .nextToOriginal, imageSpec: imageAdvanced.spec)
        let savings = estimatedSavings(
            for: items, settings: settings, imageSpec: effectiveImageSettings.imageSpec ?? imageAdvanced.spec,
            presets: presets)
        let videoItems = items.filter { !$0.isImage }
        let imageItems = items.filter(\.isImage)
        func jobs(for subset: [LibraryItem], using itemSettings: ConvertJobSettings) -> [Job] {
            guard !subset.isEmpty else { return [] }
            return PhotosJobFactory.makeJobs(
                for: subset.compactMap { item in
                    item.photosIdentifier.map {
                        (assetID: $0, name: item.name, preset: presets[item.id] ?? itemSettings.preset)
                    }
                },
                settings: itemSettings, destination: batch.destination, lost: batch.lost,
                savings: Dictionary(
                    subset.compactMap { item in
                        item.photosIdentifier.flatMap { id in savings[item.id].map { (id, $0) } }
                    }, uniquingKeysWith: { first, _ in first }))
        }
        let combinedJobs = jobs(for: videoItems, using: settings) + jobs(for: imageItems, using: effectiveImageSettings)
        let start = takeStartsQueue()
        if start { isQueuePaused = false }
        services.send { [weak self] queue in
            let added = await queue.enqueue(combinedJobs)
            if start { await queue.resume() }
            let alreadyQueued = combinedJobs.count - added.count
            await MainActor.run {
                self?.showAddNotice(alreadyQueued: alreadyQueued, unreadable: 0, missing: 0)
            }
        }
        host.requestNotificationAuthorization()
    }
}
