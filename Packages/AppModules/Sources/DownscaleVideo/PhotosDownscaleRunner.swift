import AppCore
import CoreGraphics
import Foundation
import MediaEngine
import PhotosLibrary
import Synchronization

public enum PhotosRunnerError: Error, LocalizedError, Equatable {
    /// The job's source isn't a Photos address.
    case notAPhotosJob
    /// The Mac doesn't have room for the download and the converted copy.
    case notEnoughSpace(needed: Int64)

    public var errorDescription: String? {
        switch self {
        case .notAPhotosJob: "This isn't a video in Photos"
        case .notEnoughSpace(let needed):
            "Not enough free space on this Mac to download this video (about \(needed / 1_000_000) MB needed)"
        }
    }
}

/// Converts a video in the Photos library.
///
/// 1. Reads what Photos says about it now (a deleted video fails; spatial video is refused before any download).
/// 2. Fetches the current version into the job's folder in the work folder: downloading from iCloud is its own
///    phase, with its own progress, and an edited video's rendering a second one.
/// 3. Plans, downscales and checks it with the same code as a file (`DownscaleRunner.convert`).
/// 4. Saves the result: as a new video in Photos (checked by `PhotoSaver`), or as a file in a chosen folder.
/// 5. For a Replace, after a verified save: copies the original to the originals folder when that is on, then
///    records the original as pending deletion. Nothing is deleted here; the app deletes all pending originals in
///    one batch, which the user confirms.
///
/// The job's folder is removed on every way out, so nothing of the download or the converted file stays behind.
/// The Photos library only ever gains the one new video.
public struct PhotosDownscaleRunner: JobRunner {
    private let store: any PhotoStore
    private let workFolder: WorkFolder
    private let pendingDeletions: PendingDeletions
    private let originalsBackup: DownscaleRunner.BackupProvider
    private let core: DownscaleRunner

    /// `originalsBackup` is asked at the moment of each Replace, as for files.
    public init(
        store: any PhotoStore, workFolder: WorkFolder, pendingDeletions: PendingDeletions,
        originalsBackup: @escaping DownscaleRunner.BackupProvider = { nil }
    ) {
        self.init(
            store: store, workFolder: workFolder, pendingDeletions: pendingDeletions, core: DownscaleRunner(),
            originalsBackup: originalsBackup)
    }

    /// `core` is a seam for tests (an output that looks unfaithful).
    init(
        store: any PhotoStore, workFolder: WorkFolder, pendingDeletions: PendingDeletions, core: DownscaleRunner,
        originalsBackup: @escaping DownscaleRunner.BackupProvider = { nil }
    ) {
        self.store = store
        self.workFolder = workFolder
        self.pendingDeletions = pendingDeletions
        self.core = core
        self.originalsBackup = originalsBackup
    }

    static let downloadingPhase = "Downloading from iCloud…"
    static let copyingPhase = "Getting from Photos…"
    static let renderingPhase = "Rendering the edited version…"
    static let convertingPhase = "Converting…"
    static let savingPhase = "Saving to Photos…"
    static let backupPhase = "Downloading the original for the backup…"
    static let savedNote = "Saved to Photos as a new video"
    static let recentlyDeletedNote = "Original will move to Recently Deleted"
    static let originalChanged = "The original changed during conversion"

    public func run(_ job: Job, progress: @escaping @Sendable (Double) -> Void) async throws -> JobState {
        try await run(job, progress: progress, phase: { _ in })
    }

    public func run(
        _ job: Job, progress: @escaping @Sendable (Double) -> Void, phase: @escaping @Sendable (String?) -> Void
    ) async throws -> JobState {
        do {
            return try await perform(job, progress: progress, phase: phase)
        } catch PhotoFetchError.cancelled {
            throw CancellationError()
        } catch PhotoSaveError.cancelled {
            throw CancellationError()
        }
    }

    private func perform(
        _ job: Job, progress: @escaping @Sendable (Double) -> Void, phase: @escaping @Sendable (String?) -> Void
    ) async throws -> JobState {
        let settings = try JSONDecoder().decode(DownscaleJobSettings.self, from: job.settings)
        guard let id = PhotoAssetURL.identifier(from: job.source) else { throw PhotosRunnerError.notAPhotosJob }
        let destination = settings.photosDestination ?? .newAsset
        let fetcher = PhotoInputFetcher(store: store)

        // What Photos has now: gone, or spatial, ends the job before anything is downloaded.
        let queued = try await fetcher.asset(id: id)
        if queued.subtypes.contains(.spatial) { return .keptAsIs(reason: DownscalePlanner.spatialReason) }

        let jobFolder = try workFolder.create(for: job.id)
        defer { workFolder.remove(jobID: job.id) }
        try Self.checkFreeSpace(for: queued, in: jobFolder)

        // 1. The current version.
        let input = try await fetchInput(
            id: id, asset: queued, into: jobFolder, fetcher: fetcher, progress: progress, phase: phase)
        let inventory = try await MediaInspector().inventory(of: input.url)
        // The video as the fetch read it before downloading: what the copy is made from, so what the new video is
        // checked against and what "unchanged" means. A re-read now could already include an edit made while the
        // download ran.
        let current = input.asset

        // 2. Plan, downscale and check, in the job's folder (or the chosen one).
        phase(Self.convertingPhase)
        let result = try await core.convert(
            source: input.url, byteSize: input.bytes, inventory: inventory, settings: settings,
            nameAfter: URL(filePath: PhotoInputFetcher.fileName(for: current, isEdited: false)),
            requireLossShown: true,
            outputFolder: {
                if case .folder(let bookmark) = destination {
                    return try DownscaleRunner.outputFolder(for: .folder(bookmark: bookmark), source: input.url)
                }
                return (jobFolder, {})
            }, progress: progress)
        let converted: DownscaleRunner.Conversion
        switch result {
        case .keptAsIs(let reason): return .keptAsIs(reason: reason)
        case .converted(let value): converted = value
        }

        // 3. Keep it.
        switch destination {
        case .folder:
            return .completed(
                JobOutcome(
                    output: converted.output, bytesBefore: input.bytes, bytesAfter: converted.outputSize,
                    report: converted.report, replacedOriginal: false, warnings: converted.warnings,
                    notes: converted.notes, source: job.source))
        case .newAsset, .replace:
            return try await saveToPhotos(
                job, id: id, input: input, current: current, converted: converted, replace: destination == .replace,
                jobFolder: jobFolder, fetcher: fetcher, progress: progress, phase: phase)
        }
    }

    // MARK: - Fetching

    /// Fetches the current version, reporting the download (or the copy of a video that is on this Mac) and the
    /// rendering of an edit as phases of their own.
    private func fetchInput(
        id: String, asset: PhotoAsset, into folder: URL, fetcher: PhotoInputFetcher,
        progress: @escaping @Sendable (Double) -> Void, phase: @escaping @Sendable (String?) -> Void
    ) async throws -> FetchedInput {
        let first = asset.isLocallyAvailable == true ? Self.copyingPhase : Self.downloadingPhase
        let last = Mutex<String?>(first)
        phase(first)
        return try await fetcher.fetch(id: id, into: folder) { event in
            let label =
                switch event {
                case .downloading: first
                case .exporting: Self.renderingPhase
                }
            if last.withLock({ current in
                defer { current = label }
                return current != label
            }) {
                phase(label)
            }
            progress(event.fraction)
        }
    }

    // MARK: - Saving

    private func saveToPhotos(
        _ job: Job, id: String, input: FetchedInput, current: PhotoAsset, converted: DownscaleRunner.Conversion,
        replace: Bool, jobFolder: URL, fetcher: PhotoInputFetcher, progress: @escaping @Sendable (Double) -> Void,
        phase: @escaping @Sendable (String?) -> Void
    ) async throws -> JobState {
        phase(Self.savingPhase)
        progress(0)
        var warnings = converted.warnings
        var notes = converted.notes
        var albums: [String] = []
        do {
            albums = try await store.albums(containing: id)
        } catch PhotoStoreError.notInLibrary {
            throw PhotoFetchError.notInLibrary
        } catch {
            warnings.append("The new video couldn't be added to the original's albums")
        }
        // Throws when Photos refuses, or when the new video doesn't check out (it is then removed again).
        let newID = try await PhotoSaver(store: store).save(
            file: converted.output, like: current, albums: albums,
            expectedPixelSize: Self.displaySize(of: converted.outputInventory))
        progress(1)
        notes.append(Self.savedNote)

        if replace {
            if !warnings.isEmpty {
                warnings.append(Self.keptBecause("the copy couldn't be verified"))
            } else if let problem = try await prepareReplace(
                job, id: id, input: input, current: current, newID: newID, jobFolder: jobFolder, fetcher: fetcher,
                phase: phase)
            {
                warnings.append(problem)
            } else {
                notes.append(Self.recentlyDeletedNote)
            }
        }
        return .completed(
            JobOutcome(
                output: PhotoAssetURL.url(for: newID), bytesBefore: input.bytes, bytesAfter: converted.outputSize,
                report: converted.report, replacedOriginal: false, warnings: warnings, notes: notes,
                source: job.source))
    }

    /// The Replace steps after the new video is saved and checked: the original is still the one that was
    /// converted, its backup is written when that is on, and only then it is recorded as pending deletion.
    /// Returns the warning saying why the original was kept, or nil when it was recorded.
    private func prepareReplace(
        _ job: Job, id: String, input: FetchedInput, current: PhotoAsset, newID: String, jobFolder: URL,
        fetcher: PhotoInputFetcher, phase: @escaping @Sendable (String?) -> Void
    ) async throws -> String? {
        guard await originalIsUnchanged(id: id, since: current, fetcher: fetcher) else {
            return Self.originalChanged
        }
        // A cancel from here on ends the job as cancelled: the original is not recorded, and nothing is left behind
        // (the new video was already saved and checked, so it stays).
        try Task.checkCancellation()
        if let backup = originalsBackup() {
            do {
                try await backUp(
                    input: input, id: id, into: backup.folder, jobFolder: jobFolder, fetcher: fetcher, phase: phase)
            } catch let error as OriginalsBackupError {
                return Self.keptBecause(error.keptBecause)
            } catch is CancellationError {
                throw CancellationError()
            } catch PhotoFetchError.cancelled {
                throw CancellationError()
            } catch {
                return Self.keptBecause("its original couldn't be downloaded for the backup")
            }
            try Task.checkCancellation()
            guard await originalIsUnchanged(id: id, since: current, fetcher: fetcher) else {
                return Self.originalChanged
            }
        }
        try Task.checkCancellation()
        pendingDeletions.add(assetID: id, jobID: job.id, replacedBy: newID)
        return nil
    }

    /// The original is as it was when it was fetched: still in Photos, same edit state and modification date.
    private func originalIsUnchanged(id: String, since: PhotoAsset, fetcher: PhotoInputFetcher) async -> Bool {
        guard let now = try? await fetcher.asset(id: id) else { return false }
        return now.modificationDate == since.modificationDate && now.hasAdjustments == since.hasAdjustments
    }

    /// Copies the original resource into the backup folder. The first fetch is the original itself unless the
    /// video was edited; then it is Photos' rendering, and the original is fetched again.
    private func backUp(
        input: FetchedInput, id: String, into folder: URL, jobFolder: URL, fetcher: PhotoInputFetcher,
        phase: @escaping @Sendable (String?) -> Void
    ) async throws {
        var original = input
        if input.isEditedVersion {
            phase(Self.backupPhase)
            original = try await fetcher.fetchOriginal(id: id, into: jobFolder)
        }
        _ = try core.backUp(original.url, byteSize: original.bytes, into: folder)
    }

    /// Needs room for the download and a bit more for the converted copy; a full disk would otherwise surface as a
    /// generic fetch failure after a long download.
    private static func checkFreeSpace(for asset: PhotoAsset, in folder: URL) throws {
        guard let size = asset.originalByteSize, size > 0,
            let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
        else { return }
        let needed = size + size / 4
        if free < needed { throw PhotosRunnerError.notEnoughSpace(needed: needed) }
    }

    private static func keptBecause(_ reason: String) -> String {
        "The original was kept because \(reason)"
    }

    /// The size Photos reports for the copy: as displayed, so a portrait clip is taller than wide.
    static func displaySize(of inventory: MetadataInventory) -> CGSize {
        let parts = inventory["video.dimensions"]?.value.split(separator: "x").compactMap { Double($0) } ?? []
        guard parts.count == 2 else { return .zero }
        let transform = inventory["video.transform"]?.value.split(separator: ",").compactMap { Int($0) } ?? []
        let quarterTurn = transform.count >= 4 && transform[0] == 0 && transform[3] == 0
        return quarterTurn ? CGSize(width: parts[1], height: parts[0]) : CGSize(width: parts[0], height: parts[1])
    }
}
