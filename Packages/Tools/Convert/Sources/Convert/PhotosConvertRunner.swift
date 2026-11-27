import AppCore
import CoreGraphics
import Foundation
import MediaEngine
import PhotosLibrary
import Synchronization

public enum PhotosRunnerError: Error, LocalizedError, Equatable, OutcomeCoded {
    /// The job's source isn't a Photos address.
    case notAPhotosJob

    public var errorDescription: String? {
        switch self {
        case .notAPhotosJob: "This isn't a video in Photos"
        }
    }

    public var outcomeCode: OutcomeCode {
        switch self {
        case .notAPhotosJob: .unsupportedVideo
        }
    }
}

/// Converts a video in the Photos library.
///
/// 1. Reads what Photos says about it now (a deleted video fails; spatial video is refused before any download).
/// 2. Fetches the current version into the job's folder in the work folder: downloading from iCloud is its own
///    phase, with its own progress, and an edited video's rendering a second one.
/// 3. Plans, downscales and checks it with the same code as a file (`ConvertRunner.convert`).
/// 4. Saves the result: as a new video in Photos (checked by `PhotoSaver`), or as a file in a chosen folder.
/// 5. For a Replace, after a verified save: copies the original to the originals folder when that is on, then
///    records the original as pending deletion. Nothing is deleted here; the app deletes all pending originals in
///    one batch, which the user confirms.
///
/// The job's folder is removed on every way out, so nothing of the download or the converted file stays behind.
/// The Photos library only ever gains the one new video.
public struct PhotosConvertRunner: JobRunner {
    let store: any PhotoStore
    let workFolder: WorkFolder
    let pendingDeletions: PendingDeletions
    let originalsBackup: ConvertRunner.BackupProvider
    let core: ConvertRunner
    /// One fetch from Photos at a time, however many jobs run (shared by every job this runner runs).
    let downloads: DownloadGate

    /// `originalsBackup` is asked at the moment of each Replace, as for files.
    public init(
        store: any PhotoStore, workFolder: WorkFolder, pendingDeletions: PendingDeletions,
        originalsBackup: @escaping ConvertRunner.BackupProvider = { nil }
    ) {
        self.init(
            store: store, workFolder: workFolder, pendingDeletions: pendingDeletions, core: ConvertRunner(),
            originalsBackup: originalsBackup, downloads: DownloadGate())
    }

    /// `core` is a seam for tests (an output that looks unfaithful).
    init(
        store: any PhotoStore, workFolder: WorkFolder, pendingDeletions: PendingDeletions, core: ConvertRunner,
        originalsBackup: @escaping ConvertRunner.BackupProvider = { nil }, downloads: DownloadGate = DownloadGate()
    ) {
        self.store = store
        self.workFolder = workFolder
        self.pendingDeletions = pendingDeletions
        self.core = core
        self.originalsBackup = originalsBackup
        self.downloads = downloads
    }

    static let downloadingPhase = "Downloading from iCloud…"
    static let waitingPhase = "Waiting for another download…"
    static let copyingPhase = "Getting from Photos…"
    static let renderingPhase = "Rendering the edited version…"
    static let convertingPhase = "Converting…"
    static let savingPhase = "Saving to Photos…"
    static let backupPhase = "Downloading the original for the backup…"
    static let savedNote = "Saved to Photos as a new video"
    static let recentlyDeletedNote = "Original will move to Recently Deleted"
    static let originalChanged = "The original changed during conversion"
    static let movedNote = "Original moved to Recently Deleted"

    /// Records on a finished job that its original was kept out of the batch, and why.
    public static func markOriginalKept(
        _ outcome: inout JobOutcome, because reason: String, code: OutcomeCode = .originalKeptOtherReason
    ) {
        outcome.removeNotes { text, _ in text == recentlyDeletedNote }
        outcome.addWarning(reason, code: code)
    }

    /// Records on a finished job that its original was already gone from Photos when the batch ran.
    public static func markOriginalGone(_ outcome: inout JobOutcome) {
        clearKeptWarnings(&outcome)
        outcome.removeNotes { text, _ in text == recentlyDeletedNote }
        outcome.addNote(goneNote, code: .originalGone)
    }

    private static func clearKeptWarnings(_ outcome: inout JobOutcome) {
        let messages = Set(PendingBlock.allCases.map(\.message))
        outcome.removeWarnings { text, _ in messages.contains(text) }
    }

    static let goneNote = "Original no longer in Photos"
    static let backupDownloadReason = "its original couldn't be downloaded for the backup"
    static let albumsWarning = "The new video couldn't be added to the original's albums"

    /// Records on a finished job that its original was moved to Recently Deleted.
    public static func markOriginalMoved(_ outcome: inout JobOutcome) {
        outcome.replacedOriginal = true
        clearKeptWarnings(&outcome)
        outcome.removeNotes { text, _ in text == recentlyDeletedNote || text == movedNote }
        outcome.addNote(movedNote, code: .originalInRecentlyDeleted)
    }

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
        let settings = try JSONDecoder().decode(ConvertJobSettings.self, from: job.settings)
        guard let id = PhotoAssetURL.identifier(from: job.source) else { throw PhotosRunnerError.notAPhotosJob }
        defer { core.diskSpace.release(owner: job.id) }
        let destination = settings.photosDestination ?? .newAsset
        let fetcher = PhotoInputFetcher(store: store)

        // A job put back in the queue after its copy was saved (a crash, or a quit) carries on from there: it never
        // saves a second copy.
        if let saved = pendingDeletions.savedCopy(for: job.id), saved.originalID == id {
            switch destination {
            case .folder: break
            case .newAsset, .replace:
                if let state = try await resume(
                    job, saved: saved, replace: destination == .replace, fetcher: fetcher, phase: phase)
                {
                    return state
                }
            }
        }

        // What Photos has now: gone, or spatial, ends the job before anything is downloaded.
        let queued = try await fetcher.asset(id: id)
        if queued.mediaKind == .image || settings.imageSpec != nil || job.toolID == ConvertTool.imagePhotosToolID {
            return try await performImageJob(
                job, id: id, asset: queued, settings: settings, destination: destination, fetcher: fetcher,
                progress: progress, phase: phase)
        }
        if queued.subtypes.contains(.spatial) {
            return .keptAsIs(reason: ConvertPlanner.spatialReason, code: .spatialVideo)
        }

        // Nothing is written, not even the job's folder, unless every volume involved has room.
        try checkFreeSpaceBeforeDownload(queued, settings: settings, destination: destination, jobID: job.id)
        let jobFolder = try workFolder.create(for: job.id)
        defer { workFolder.remove(jobID: job.id) }

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
            requireLossShown: true, reservingFor: job.id,
            outputFolder: {
                if case .folder(let bookmark) = destination {
                    return try ConvertRunner.outputFolder(for: .folder(bookmark: bookmark), source: input.url)
                }
                return (jobFolder, {})
            }, progress: progress)
        let converted: ConvertRunner.Conversion
        switch result {
        case .keptAsIs(let reason, let code): return .keptAsIs(reason: reason, code: code)
        case .converted(let value): converted = value
        }

        // 3. Keep it.
        switch destination {
        case .folder:
            return .completed(
                JobOutcome(
                    output: converted.output, bytesBefore: input.bytes, bytesAfter: converted.outputSize,
                    report: converted.report, replacedOriginal: false, warnings: converted.warnings.map(\.text),
                    warningCodes: converted.warnings.map(\.code), notes: converted.notes.map(\.text),
                    noteCodes: converted.notes.map(\.code), source: job.source))
        case .newAsset, .replace:
            return try await saveToPhotos(
                job, id: id, input: input, current: current, converted: converted, replace: destination == .replace,
                jobFolder: jobFolder, fetcher: fetcher, progress: progress, phase: phase)
        }
    }

    // MARK: - Fetching

    /// Fetches the current version, reporting the download (or the copy of a video that is on this Mac) and the
    /// rendering of an edit as phases of their own.
    func fetchInput(
        id: String, asset: PhotoAsset, into folder: URL, fetcher: PhotoInputFetcher,
        progress: @escaping @Sendable (Double) -> Void, phase: @escaping @Sendable (String?) -> Void
    ) async throws -> FetchedInput {
        let first = asset.isLocallyAvailable == true ? Self.copyingPhase : Self.downloadingPhase
        let last = Mutex<String?>(first)
        // Only one fetch at a time; a job waiting for its turn reports waiting inside the gate and can still cancel.
        return try await downloads.run(onWait: { phase(Self.waitingPhase) }) {
            phase(first)
            return try await Signposts.interval(.download) {
                try await fetcher.fetch(id: id, into: folder) { event in
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
        }
    }

    // MARK: - Saving

    private func saveToPhotos(
        _ job: Job, id: String, input: FetchedInput, current: PhotoAsset, converted: ConvertRunner.Conversion,
        replace: Bool, jobFolder: URL, fetcher: PhotoInputFetcher, progress: @escaping @Sendable (Double) -> Void,
        phase: @escaping @Sendable (String?) -> Void
    ) async throws -> JobState {
        // The work copy stays until the job ends, so the library's volume needs the whole converted file as well.
        try core.diskSpace.verify([SpaceNeed(url: Self.photosLibraryLocation, bytes: converted.outputSize)])
        phase(Self.savingPhase)
        progress(0)
        var warnings = converted.warnings
        var albums: [String] = []
        do {
            albums = try await store.albums(containing: id)
        } catch PhotoStoreError.notInLibrary {
            throw PhotoFetchError.notInLibrary
        } catch {
            warnings.append(OutcomeLine(Self.albumsWarning, .notAddedToAlbums))
        }
        let savedLine = OutcomeLine(Self.savedNote, .savedToPhotos)
        // Throws when Photos refuses, or when the new video doesn't check out (it is then removed again).
        let newID = try await Signposts.interval(.save) {
            try await PhotoSaver(store: store).save(
                file: converted.output, like: current, albums: albums,
                expectedPixelSize: Self.displaySize(of: converted.outputInventory))
        }
        progress(1)

        var outcome = JobOutcome(
            output: PhotoAssetURL.url(for: newID), bytesBefore: input.bytes, bytesAfter: converted.outputSize,
            report: converted.report, replacedOriginal: false, warnings: warnings.map(\.text),
            warningCodes: warnings.map(\.code), notes: (converted.notes + [savedLine]).map(\.text),
            noteCodes: (converted.notes + [savedLine]).map(\.code), source: job.source)
        // From here a second attempt must not save again, so the saved copy is written down at once.
        pendingDeletions.markSaved(
            SavedCopy(
                jobID: job.id, originalID: id, newID: newID, outcome: outcome,
                originalModified: current.modificationDate, originalHadAdjustments: current.hasAdjustments))
        if replace {
            try await finishReplace(
                job, id: id, outcome: &outcome, input: input, jobFolder: jobFolder, fetcher: fetcher, phase: phase)
        }
        return .completed(outcome)
    }

    // MARK: - Carrying on after a crash or a quit

    /// The job's copy was saved by an earlier attempt that didn't finish. Returns the finished job, or nil when the
    /// copy is no longer in Photos (the user removed it), so the video is converted again from the start.
    private func resume(
        _ job: Job, saved: SavedCopy, replace: Bool, fetcher: PhotoInputFetcher,
        phase: @escaping @Sendable (String?) -> Void
    ) async throws -> JobState? {
        do {
            _ = try await fetcher.asset(id: saved.newID)
        } catch PhotoFetchError.notInLibrary {
            pendingDeletions.forgetSavedCopy(forJob: job.id)
            return nil
        }
        var outcome = saved.outcome
        guard replace else { return .completed(outcome) }
        // The original may be gone by now; the copy is saved, so the job still finishes, with nothing to delete.
        do {
            _ = try await fetcher.asset(id: saved.originalID)
        } catch PhotoFetchError.notInLibrary {
            return .completed(outcome)
        }
        if pendingDeletions.all.contains(where: { $0.assetID == saved.originalID && $0.jobID == job.id }) {
            outcome.addNote(Self.recentlyDeletedNote, code: .originalInRecentlyDeleted)
            return .completed(outcome)
        }
        let jobFolder = try workFolder.create(for: job.id)
        defer { workFolder.remove(jobID: job.id) }
        try await finishReplace(
            job, id: saved.originalID, outcome: &outcome, input: nil, jobFolder: jobFolder, fetcher: fetcher,
            phase: phase)
        return .completed(outcome)
    }

    // MARK: - Replace

    /// The Replace steps after the new video is saved and checked: adds to `outcome` the note that the original will
    /// move to Recently Deleted, or the warning saying why it was kept.
    func finishReplace(
        _ job: Job, id: String, outcome: inout JobOutcome, input: FetchedInput?, jobFolder: URL,
        fetcher: PhotoInputFetcher, phase: @escaping @Sendable (String?) -> Void
    ) async throws {
        if !outcome.warnings.isEmpty {
            outcome.addWarning(
                Self.keptBecause(ConvertRunner.unverifiedCopyReason), code: .originalKeptNotVerified)
        } else if let problem = try await prepareReplace(
            job, id: id, input: input, jobFolder: jobFolder, fetcher: fetcher, phase: phase)
        {
            outcome.addWarning(problem.text, code: problem.code)
        } else {
            outcome.addNote(Self.recentlyDeletedNote, code: .originalInRecentlyDeleted)
        }
    }

    /// The original is still the one that was converted, its backup is written when that is on, and only then it is
    /// recorded as pending deletion. Returns the warning saying why the original was kept, or nil when it was
    /// recorded.
    ///
    /// A cancel from here on ends the job as cancelled: the original is not recorded, and nothing is left behind
    /// (the new video was already saved and checked, so it stays). That includes the backup written in this step: it
    /// would have no record to say what it was for, so it is removed again. (A backup of an original that changed
    /// meanwhile is kept: it is a whole, checked copy, and the job says why the original was kept.)
    private func prepareReplace(
        _ job: Job, id: String, input: FetchedInput?, jobFolder: URL, fetcher: PhotoInputFetcher,
        phase: @escaping @Sendable (String?) -> Void
    ) async throws -> OutcomeLine? {
        let changed = OutcomeLine(Self.originalChanged, .originalChangedDuringConversion)
        guard let saved = pendingDeletions.savedCopy(for: job.id) else { return changed }
        guard await originalIsUnchanged(id: id, saved: saved, fetcher: fetcher) else { return changed }
        try Task.checkCancellation()
        var writtenBackup: URL?
        do {
            if let backup = originalsBackup() {
                if let existing = saved.backup, FileManager.default.fileExists(atPath: existing.path) {
                    // An earlier attempt already wrote it.
                } else {
                    do {
                        let url = try await backUp(
                            input: input, id: id, into: backup.folder, jobFolder: jobFolder, fetcher: fetcher,
                            phase: phase)
                        writtenBackup = url
                        pendingDeletions.setBackup(url, forJob: job.id)
                    } catch let error as OriginalsBackupError {
                        return OutcomeLine(Self.keptBecause(error.keptBecause), .originalKeptBackupFailed)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch PhotoFetchError.cancelled {
                        throw CancellationError()
                    } catch {
                        return OutcomeLine(Self.keptBecause(Self.backupDownloadReason), .originalKeptBackupFailed)
                    }
                }
                try Task.checkCancellation()
                guard await originalIsUnchanged(id: id, saved: saved, fetcher: fetcher) else { return changed }
            }
            try Task.checkCancellation()
            pendingDeletions.add(
                assetID: id, jobID: job.id, replacedBy: saved.newID, originalModified: saved.originalModified,
                originalHadAdjustments: saved.originalHadAdjustments)
            return nil
        } catch is CancellationError {
            if let writtenBackup {
                try? FileManager.default.removeItem(at: writtenBackup)
                pendingDeletions.setBackup(nil, forJob: job.id)
            }
            throw CancellationError()
        }
    }

    /// The original is as it was when the copy was made from it: still in Photos, same edit state and modification
    /// date.
    private func originalIsUnchanged(id: String, saved: SavedCopy, fetcher: PhotoInputFetcher) async -> Bool {
        guard let now = try? await fetcher.asset(id: id) else { return false }
        return now.modificationDate == saved.originalModified && now.hasAdjustments == saved.originalHadAdjustments
    }

    /// Copies the original resource into the backup folder and returns the copy. The first fetch is the original
    /// itself unless the video was edited; then it is Photos' rendering, and the original is fetched again. Without
    /// the first fetch (a job carrying on after a restart) the original is fetched here.
    private func backUp(
        input: FetchedInput?, id: String, into folder: URL, jobFolder: URL, fetcher: PhotoInputFetcher,
        phase: @escaping @Sendable (String?) -> Void
    ) async throws -> URL {
        var original = input
        // The copy goes to the backup volume and is as big as the original. The first fetch is the original only when
        // the video wasn't edited; for an edited one its size is Photos' rendering, not the original, so nothing is
        // checked from it: the original is fetched next (a full job folder fails that fetch) and `core.backUp` checks
        // the backup volume with the original's own size before copying.
        if let input, !input.isEditedVersion {
            do {
                try core.diskSpace.verify([SpaceNeed(url: folder, bytes: input.bytes)])
            } catch { throw OriginalsBackupError.notEnoughSpace }
        }
        if input == nil || input?.isEditedVersion == true {
            phase(Self.backupPhase)
            original = try await downloads.run { try await fetcher.fetchOriginal(id: id, into: jobFolder) }
        }
        guard let original else { throw OriginalsBackupError.copyFailed }
        return try core.backUp(original.url, byteSize: original.bytes, into: folder)
    }

    // MARK: - Free space

    /// Where the system Photos library lives (`~/Pictures`), for the volume that holds the copy saved into it.
    static let photosLibraryLocation = URL.picturesDirectory

    /// Before a download (and before the job's folder exists): the Work volume must hold the video as Photos has it,
    /// plus the converted copy when that is written there; a chosen output folder, the converted copy; an originals
    /// backup, the original (and, for an edited video, the original's own download in the Work volume too). Each
    /// volume also keeps `DiskSpaceCheck.margin` free. The converted copy's size is the planner's estimate for what
    /// Photos reports about the video; the exact estimate is checked again once the video is read
    /// (`ConvertRunner.convert`). Skipped when Photos doesn't say how big the video is.
    private func checkFreeSpaceBeforeDownload(
        _ asset: PhotoAsset, settings: ConvertJobSettings, destination: PhotosDestination, jobID: UUID
    ) throws {
        guard let size = asset.originalByteSize, size > 0 else { return }
        let profile = SourceProfile(
            width: Int(asset.pixelSize.width), height: Int(asset.pixelSize.height), durationSeconds: asset.duration,
            byteSize: size)
        let spec = settings.spec(for: profile)
        let output = min(Estimator.estimatedBytes(source: profile, spec: spec), size)
        let work = workFolder.url(for: jobID)

        var needs = [SpaceNeed(url: work, bytes: size)]
        if case .folder(let bookmark) = destination {
            // An unusable folder is reported when the output is about to be written.
            if let folder = try? ConvertRunner.outputFolder(for: .folder(bookmark: bookmark), source: work) {
                needs.append(SpaceNeed(url: folder.url, bytes: output))
                folder.stop()
            }
        } else {
            needs.append(SpaceNeed(url: work, bytes: output))
            // Saving copies the converted file into the Photos library while the work copy still exists.
            needs.append(SpaceNeed(url: Self.photosLibraryLocation, bytes: output))
        }
        if destination == .replace, let backup = originalsBackup() {
            needs.append(SpaceNeed(url: backup.folder, bytes: size))
            if asset.hasAdjustments { needs.append(SpaceNeed(url: work, bytes: size)) }
        }
        try core.diskSpace.verify(needs, reservingFor: jobID)
    }

    static func keptBecause(_ reason: String) -> String {
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
