import AppCore
import CoreGraphics
import Foundation
import MediaEngine
import PhotosLibrary

extension PhotosConvertRunner {
    /// Image & Live Photo execution path inside `PhotosConvertRunner` so videos and images share the same
    /// `DownloadGate`, `WorkFolder`, `PendingDeletions`, and Replace-confirmation flow.
    func performImageJob(
        _ job: Job,
        id: String,
        asset queued: PhotoAsset,
        settings: ConvertJobSettings,
        destination: PhotosDestination,
        fetcher: PhotoInputFetcher,
        progress: @escaping @Sendable (Double) -> Void,
        phase: @escaping @Sendable (String?) -> Void
    ) async throws -> JobState {
        let imageSpec = settings.imageSpec ?? ImageSpec()
        try checkImageFreeSpaceBeforeDownload(
            queued, spec: imageSpec, destination: destination, jobID: job.id)

        let jobFolder = try workFolder.create(for: job.id)
        defer { workFolder.remove(jobID: job.id) }

        // 1. Fetch primary still/edited image (and paired .mov when preserving a Live Photo).
        let input = try await fetchInput(
            id: id, asset: queued, into: jobFolder, fetcher: fetcher, progress: progress, phase: phase)
        let current = input.asset

        var pairedVideoURL: URL?
        if current.isLivePhoto, imageSpec.livePhotoMode == .preserve, destination != .folder(bookmark: Data()) {
            // Destination folder only receives the still image (or Photos saves a Live Photo when .newAsset/.replace).
            if case .folder = destination {
                pairedVideoURL = nil
            } else {
                pairedVideoURL = try? await downloads.run(onWait: { phase(Self.waitingPhase) }) {
                    phase(Self.copyingPhase)
                    return try await fetcher.fetchPairedVideo(
                        id: id, into: jobFolder, asset: current, originalOnly: false
                    ) { event in
                        progress(event.fraction)
                    }
                }
            }
        }

        // 2. Inspect and convert the image.
        let inspector = ImageInspector()
        let inspection = try inspector.inspect(url: input.url)
        let inventory = try inspector.inventory(of: input.url)

        phase(Self.convertingPhase)
        let imageRunner = ImageConvertRunner(core: core)
        let result = try await imageRunner.convert(
            source: input.url,
            byteSize: input.bytes,
            inspection: inspection,
            inventory: inventory,
            settings: settings,
            spec: imageSpec,
            nameAfter: URL(filePath: PhotoInputFetcher.fileName(for: current, isEdited: false)),
            requireLossShown: true,
            reservingFor: job.id,
            outputFolder: {
                if case .folder(let bookmark) = destination {
                    return try ConvertRunner.outputFolder(for: .folder(bookmark: bookmark), source: input.url)
                }
                return (jobFolder, {})
            },
            progress: progress
        )

        let converted: ConvertRunner.Conversion
        switch result {
        case .keptAsIs(let reason, let code):
            return .keptAsIs(reason: reason, code: code)
        case .converted(let value):
            converted = value
        }

        // Optional paired video shrink when preserving Live Photo.
        var convertedPairedURL: URL?
        if let pairedURL = pairedVideoURL {
            convertedPairedURL = try await convertPairedVideoIfSmaller(pairedURL, in: jobFolder)
        }

        // 3. Save output.
        switch destination {
        case .folder:
            return .completed(
                JobOutcome(
                    output: converted.output, bytesBefore: input.bytes, bytesAfter: converted.outputSize,
                    report: converted.report, replacedOriginal: false,
                    warnings: converted.warnings.map(\.text), warningCodes: converted.warnings.map(\.code),
                    notes: converted.notes.map(\.text), noteCodes: converted.notes.map(\.code),
                    source: job.source))
        case .newAsset, .replace:
            return try await saveImageToPhotos(
                job, id: id, input: input, current: current, converted: converted,
                pairedVideoURL: convertedPairedURL, replace: destination == .replace,
                jobFolder: jobFolder, fetcher: fetcher, progress: progress, phase: phase)
        }
    }

    private func convertPairedVideoIfSmaller(_ pairedURL: URL, in folder: URL) async throws -> URL {
        // Attempt gentle HEVC 1080p shrink of paired Live Photo video; fall back to original paired video if
        // already compact or kept as is.
        let outURL = folder.appending(path: "paired-shrunk-\(UUID().uuidString).mov")
        let spec = DownscaleSpec(
            targetShortSide: 1080, averageBitRate: 4_000_000, maxFrameRate: nil, codec: .hevcKeepHDR)
        do {
            try await VideoDownscaler().downscale(source: pairedURL, output: outURL, spec: spec) { _ in }
            let origSize = (try? core.sizeOf(pairedURL)) ?? 0
            let newSize = (try? core.sizeOf(outURL)) ?? 0
            if newSize > 0, newSize < origSize {
                return outURL
            }
            try? FileManager.default.removeItem(at: outURL)
        } catch {
            try? FileManager.default.removeItem(at: outURL)
        }
        return pairedURL
    }

    private func saveImageToPhotos(
        _ job: Job,
        id: String,
        input: FetchedInput,
        current: PhotoAsset,
        converted: ConvertRunner.Conversion,
        pairedVideoURL: URL?,
        replace: Bool,
        jobFolder: URL,
        fetcher: PhotoInputFetcher,
        progress: @escaping @Sendable (Double) -> Void,
        phase: @escaping @Sendable (String?) -> Void
    ) async throws -> JobState {
        let pairedSize = pairedVideoURL.flatMap { try? core.sizeOf($0) } ?? 0
        try core.diskSpace.verify([
            SpaceNeed(url: Self.photosLibraryLocation, bytes: converted.outputSize + pairedSize)
        ])
        phase(Self.savingPhase)
        progress(0)
        var warnings = converted.warnings
        var albums: [String] = []
        do {
            albums = try await store.albums(containing: id)
        } catch PhotoStoreError.notInLibrary {
            throw PhotoFetchError.notInLibrary
        } catch {
            warnings.append(OutcomeLine("The new photo couldn't be added to the original's albums", .notAddedToAlbums))
        }
        let savedLine = OutcomeLine("Saved to Photos as a new photo", .savedToPhotos)
        let expectedSize = Self.imageDisplaySize(of: converted.outputInventory, fallback: current.pixelSize)
        let newID = try await Signposts.interval(.save) {
            try await PhotoSaver(store: store).saveImage(
                file: converted.output, pairedVideoFile: pairedVideoURL, like: current, albums: albums,
                expectedPixelSize: expectedSize)
        }
        progress(1)

        var outcome = JobOutcome(
            output: PhotoAssetURL.url(for: newID), bytesBefore: input.bytes,
            bytesAfter: converted.outputSize + pairedSize,
            report: converted.report, replacedOriginal: false,
            warnings: warnings.map(\.text), warningCodes: warnings.map(\.code),
            notes: (converted.notes + [savedLine]).map(\.text),
            noteCodes: (converted.notes + [savedLine]).map(\.code),
            source: job.source)

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

    private func checkImageFreeSpaceBeforeDownload(
        _ asset: PhotoAsset, spec: ImageSpec, destination: PhotosDestination, jobID: UUID
    ) throws {
        guard let size = asset.originalByteSize, size > 0 else { return }
        let paired = asset.isLivePhoto ? (asset.pairedVideoByteSize ?? 0) : 0
        let totalDownload = size + paired
        let est = ImageEstimator.estimatedBytes(
            byteSize: size, sourcePixelSize: asset.pixelSize,
            targetPixelSize: spec.outputPixelSize(for: asset.pixelSize),
            sourceUTI: "public.heic", spec: spec, isLivePhoto: asset.isLivePhoto,
            pairedVideoByteSize: asset.pairedVideoByteSize)
        let work = workFolder.url(for: jobID)
        var needs = [SpaceNeed(url: work, bytes: totalDownload)]
        if case .folder(let bookmark) = destination {
            if let folder = try? ConvertRunner.outputFolder(for: .folder(bookmark: bookmark), source: work) {
                needs.append(SpaceNeed(url: folder.url, bytes: est))
                folder.stop()
            }
        } else {
            needs.append(SpaceNeed(url: work, bytes: est))
            needs.append(SpaceNeed(url: Self.photosLibraryLocation, bytes: est))
        }
        if destination == .replace, let backup = originalsBackup() {
            needs.append(SpaceNeed(url: backup.folder, bytes: totalDownload))
        }
        try core.diskSpace.verify(needs, reservingFor: jobID)
    }

    private static func imageDisplaySize(of inventory: MetadataInventory, fallback: CGSize) -> CGSize {
        let parts = inventory["img.dimensions"]?.value.split(separator: "x").compactMap { Double($0) } ?? []
        guard parts.count == 2 else { return fallback }
        return CGSize(width: parts[0], height: parts[1])
    }
}
