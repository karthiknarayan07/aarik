import AppCore
import Foundation
import MediaEngine
import MediaTestSupport
import PhotosLibrary
import Synchronization
import Testing

@testable import Convert

/// Converting a Photos video: fetch, plan, downscale in the work folder, save a verified new video, optionally
/// queue the original for deletion. The library is a fake; the clip is real.
@Suite(.enabled(if: EncoderEnvironment.isRepresentative)) struct PhotosRunnerTests {
    private func completed(_ state: JobState) -> JobOutcome? {
        if case .completed(let outcome) = state { return outcome }
        Issue.record("expected completed, got \(state)")
        return nil
    }

    // MARK: - New asset

    @Test(.timeLimit(.minutes(5))) func newAssetSavesAVerifiedCopyAndLeavesTheOriginalAlone() async throws {
        let rig = try await PhotosRig(albums: ["album-1"])
        let log = RunLog()

        let state = try await log.run(rig.runner(), try rig.job())

        let outcome = try #require(completed(state))
        #expect(outcome.output == PhotoAssetURL.url(for: "new-1"))
        #expect(outcome.source == PhotoAssetURL.url(for: rig.asset.id))
        #expect(!outcome.replacedOriginal)
        #expect(outcome.isVerified)
        #expect(outcome.bytesAfter < outcome.bytesBefore)
        let save = try #require(rig.store.saves.first)
        #expect(rig.store.saves.count == 1)
        #expect(save.request.creationDate == rig.asset.creationDate)
        #expect(save.request.location == rig.asset.location)
        #expect(save.request.isFavorite)
        #expect(save.addedAlbums == ["album-1"])
        #expect(rig.store.deletedIDs.isEmpty)
        #expect(rig.pending.all.isEmpty)
        #expect(rig.workContents.isEmpty)
        #expect(outcome.notes == ["Saved to Photos as a new video"])
        #expect(outcome.noteCodes == [.savedToPhotos])
    }

    @Test(.timeLimit(.minutes(5))) func theCopyKeepsEveryAttributeOfTheOriginal() async throws {
        let rig = try await PhotosRig(albums: ["album-1", "album-2"], isHidden: true)

        let state = try await RunLog().run(rig.runner(), try rig.job(.replace))

        let outcome = try #require(completed(state))
        let newID = try #require(PhotoAssetURL.identifier(from: outcome.output))
        let copy = try await rig.store.asset(id: newID)
        #expect(copy.creationDate == rig.asset.creationDate)
        #expect(copy.location == rig.asset.location)
        #expect(copy.isFavorite)
        #expect(copy.isHidden)
        #expect(copy.caption == "Trip to Paris")
        #expect(try await rig.store.albums(containing: newID) == ["album-1", "album-2"])
        // The original is only recorded for deletion, after the copy checked out and is in its albums.
        #expect(rig.store.deletedIDs.isEmpty)
        #expect(rig.pending.all.map(\.assetID) == [rig.asset.id])

        // Moving the original to Recently Deleted leaves the copy and every attribute/album intact.
        let deletion = try await OriginalsDeleter.deleteAll(store: rig.store, pending: rig.pending)
        #expect(deletion.moved.map(\.assetID) == [rig.asset.id])
        #expect(rig.store.deletedIDs == [rig.asset.id])
        #expect(try await rig.store.albums(containing: newID) == ["album-1", "album-2"])
    }

    @Test(.timeLimit(.minutes(5))) func anAlbumMissingFromTheCopyRemovesTheCopyAndKeepsTheOriginal() async throws {
        let rig = try await PhotosRig(albums: ["album-1", "album-2"])
        rig.store.existingAlbums = ["album-1"]

        do {
            _ = try await rig.runner().run(try rig.job(.replace)) { _ in }
            Issue.record("expected verifyFailed")
        } catch let PhotoSaveError.verifyFailed(reasons, cleanup) {
            #expect(cleanup == .removed)
            #expect(reasons.contains { $0.contains("albums") })
        }
        #expect(rig.store.deletedIDs == ["new-1"])
        #expect(rig.pending.all.isEmpty)
        #expect(rig.store.assets.map(\.id) == [rig.asset.id])
    }

    @Test(.timeLimit(.minutes(5))) func theDownloadIsItsOwnPhaseWithItsOwnProgress() async throws {
        let rig = try await PhotosRig()
        let log = RunLog()

        _ = try await log.run(rig.runner(), try rig.job())

        #expect(log.phases == ["Downloading from iCloud…", "Converting…", "Saving to Photos…"])
        // The download counted 0.25, 0.5, 0.75, 1 on its own; the conversion then started over.
        #expect(log.progress.prefix(4).map { $0 } == [0.25, 0.5, 0.75, 1])
    }

    @Test(.timeLimit(.minutes(5))) func aVideoOnThisMacIsNotCalledAnICloudDownload() async throws {
        let rig = try await PhotosRig()
        let local = PhotoAsset(
            id: rig.asset.id, creationDate: rig.asset.creationDate, location: rig.asset.location,
            pixelSize: rig.asset.pixelSize, duration: 1.0, originalFileName: "IMG_0001.MOV",
            originalByteSize: rig.asset.originalByteSize, isLocallyAvailable: true)
        rig.store.assets = [local]
        let log = RunLog()

        _ = try await log.run(rig.runner(), try rig.job())

        #expect(log.phases.first == "Getting from Photos…")
    }

    @Test(.timeLimit(.minutes(5))) func anEditsRenderingMayBeAFewMillisecondsLonger() async throws {
        let rig = try await PhotosRig(hasAdjustments: true, savedDuration: 1.002)

        let state = try await rig.runner().run(try rig.job()) { _ in }

        let outcome = try #require(completed(state))
        #expect(outcome.isVerified)
        #expect(rig.store.inputRequests.map(\.kind) == [.currentVersion])
        #expect(rig.store.deletedIDs.isEmpty)
    }

    @Test(.timeLimit(.minutes(5))) func anEditedVersionNeverSeenWhenQueuedIsUsedAtRunTime() async throws {
        let rig = try await PhotosRig()
        let job = try rig.job()  // queued while the video was not edited
        let edited = PhotoAsset(
            id: rig.asset.id, creationDate: rig.asset.creationDate, location: rig.asset.location,
            pixelSize: rig.asset.pixelSize, duration: 1.0, hasAdjustments: true,
            originalFileName: "IMG_0001.MOV", originalByteSize: rig.asset.originalByteSize,
            isLocallyAvailable: false)
        rig.store.assets = [edited]  // edited before the run

        _ = try await rig.runner().run(job) { _ in }

        #expect(rig.store.inputRequests.map(\.kind) == [.currentVersion])
    }

    // MARK: - Folder

    @Test(.timeLimit(.minutes(5))) func folderDestinationWritesAFileAndChangesNothingInPhotos() async throws {
        let rig = try await PhotosRig()
        let folder = rig.directory.appending(path: "Out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bookmark = try folder.bookmarkData()

        let state = try await rig.runner().run(try rig.job(.folder(bookmark: bookmark))) { _ in }

        let outcome = try #require(completed(state))
        #expect(outcome.output.isFileURL)
        #expect(
            outcome.output.deletingLastPathComponent().resolvingSymlinksInPath() == folder.resolvingSymlinksInPath())
        #expect(outcome.output.lastPathComponent == "IMG_0001 (1080p).MOV")
        #expect(FileManager.default.fileExists(atPath: outcome.output.path))
        #expect(rig.store.saves.isEmpty)
        #expect(rig.store.deletedIDs.isEmpty)
        #expect(rig.workContents.isEmpty)
    }

    // MARK: - Replace

    @Test(.timeLimit(.minutes(5))) func replaceRecordsTheOriginalAsPendingAndDeletesNothing() async throws {
        let rig = try await PhotosRig()
        let job = try rig.job(.replace)

        let state = try await rig.runner().run(job) { _ in }

        let outcome = try #require(completed(state))
        #expect(outcome.output == PhotoAssetURL.url(for: "new-1"))
        #expect(!outcome.replacedOriginal)
        #expect(outcome.notes == ["Saved to Photos as a new video", "Original will move to Recently Deleted"])
        #expect(outcome.noteCodes == [.savedToPhotos, .originalInRecentlyDeleted])
        #expect(rig.pending.all == [PendingDeletion(assetID: rig.asset.id, jobID: job.id, replacedBy: "new-1")])
        #expect(rig.store.deletedIDs.isEmpty)
        #expect(!rig.store.operations.contains { if case .delete = $0 { true } else { false } })
        // The new video was saved and verified before the original was recorded.
        #expect(rig.store.operations.firstIndex(of: .save) != nil)
    }

    @Test(.timeLimit(.minutes(5))) func replaceCopiesTheOriginalToTheBackupFolderFirst() async throws {
        let rig = try await PhotosRig()
        let originalSize = try #require(RunnerFixture.size(rig.clip))

        let state = try await rig.runner(backup: true).run(try rig.job(.replace)) { _ in }

        _ = try #require(completed(state))
        #expect(rig.backupContents == ["IMG_0001.MOV"])
        #expect(RunnerFixture.size(rig.backup.appending(path: "IMG_0001.MOV")) == originalSize)
        #expect(rig.pending.all.count == 1)
        #expect(rig.store.inputRequests.map(\.kind) == [.original])
    }

    @Test(.timeLimit(.minutes(5))) func anEditedVideosBackupIsItsOriginalFromASecondFetch() async throws {
        let rig = try await PhotosRig(hasAdjustments: true)
        let original = try await RunnerFixture.smallSource(name: "original.mov")
        defer { try? FileManager.default.removeItem(at: original.deletingLastPathComponent()) }
        rig.store.originalFiles[rig.asset.id] = original
        let log = RunLog()

        let state = try await log.run(rig.runner(backup: true), try rig.job(.replace))

        _ = try #require(completed(state))
        #expect(rig.store.inputRequests.map(\.kind) == [.currentVersion, .original])
        #expect(rig.backupContents == ["IMG_0001.MOV"])
        #expect(RunnerFixture.size(rig.backup.appending(path: "IMG_0001.MOV")) == RunnerFixture.size(original))
        #expect(log.phases.contains("Downloading the original for the backup…"))
        #expect(rig.pending.all.count == 1)
        #expect(rig.workContents.isEmpty)
    }

    @Test(.timeLimit(.minutes(5))) func aBackupThatFailsKeepsTheOriginalOffTheDeleteList() async throws {
        let rig = try await PhotosRig()
        try FileManager.default.removeItem(at: rig.backup)  // the drive isn't there

        let state = try await rig.runner(backup: true).run(try rig.job(.replace)) { _ in }

        let outcome = try #require(completed(state))
        #expect(rig.pending.all.isEmpty)
        #expect(outcome.warnings.contains { $0.hasPrefix("The original was kept because") })
        // The copy was already saved and checked; it stays.
        #expect(rig.store.saves.count == 1)
        #expect(rig.store.deletedIDs.isEmpty)
    }

    @Test(.timeLimit(.minutes(5))) func aCopyWithMetadataWarningsNeverQueuesTheOriginal() async throws {
        let rig = try await PhotosRig()
        let core = ConvertRunner(
            trash: { $0 },
            inspect: { url in
                var inventory = try await MediaInspector().inventory(of: url)
                inventory.items = inventory.items.map {
                    $0.key == "video.bitDepth"
                        ? MetadataItem(key: $0.key, category: $0.category, displayName: $0.displayName, value: "10")
                        : $0
                }
                return inventory
            },
            diskSpace: RunnerFixture.roomy)

        let state = try await rig.runner(core: core).run(try rig.job(.replace)) { _ in }

        let outcome = try #require(completed(state))
        #expect(!outcome.isVerified)
        #expect(rig.pending.all.isEmpty)
        #expect(outcome.warnings.last == "The original was kept because the copy couldn't be verified")
        #expect(outcome.warningCodes.last == .originalKeptNotVerified)
    }

    @Test(.timeLimit(.minutes(5))) func anOriginalEditedDuringTheRunIsKept() async throws {
        let rig = try await PhotosRig()
        let changed = PhotoAsset(
            id: rig.asset.id, creationDate: rig.asset.creationDate, location: rig.asset.location,
            pixelSize: rig.asset.pixelSize, duration: 1.0, hasAdjustments: true,
            originalFileName: "IMG_0001.MOV", originalByteSize: rig.asset.originalByteSize,
            isLocallyAvailable: false, modificationDate: Date())
        // Photos changes the video while the new one is being saved.
        rig.store.afterSave = { [store = rig.store] in
            store.assets = [changed] + store.assets.filter { $0.id != changed.id }
        }

        let state = try await rig.runner().run(try rig.job(.replace)) { _ in }

        let outcome = try #require(completed(state))
        #expect(rig.pending.all.isEmpty)
        #expect(outcome.warnings == ["The original changed during conversion"])
        #expect(outcome.warningCodes == [.originalChangedDuringConversion])
    }

    // MARK: - Refusals and failures

    @Test(.timeLimit(.minutes(5))) func spatialVideoIsRefusedBeforeAnyDownload() async throws {
        let rig = try await PhotosRig(subtypes: [.spatial])

        let state = try await rig.runner().run(try rig.job()) { _ in }

        #expect(state == .keptAsIs(reason: ConvertPlanner.spatialReason, code: .spatialVideo))
        #expect(rig.store.inputRequests.isEmpty)
        #expect(rig.store.saves.isEmpty)
        #expect(rig.workContents.isEmpty)
    }

    @Test(.timeLimit(.minutes(5))) func offlineDownloadFailsTheJobWithNoNewVideoAndNoFilesLeft() async throws {
        let rig = try await PhotosRig()
        rig.store.inputError = .downloadFailed("offline")

        do {
            _ = try await rig.runner().run(try rig.job()) { _ in }
            Issue.record("expected the run to throw")
        } catch {
            #expect(error.localizedDescription.hasPrefix("Couldn't download from iCloud"))
            #expect(error as? PhotoFetchError == .downloadFailed(underlying: "offline"))
        }
        #expect(rig.store.saves.isEmpty)
        #expect(rig.store.deletedIDs.isEmpty)
        #expect(rig.pending.all.isEmpty)
        #expect(rig.workContents.isEmpty)
        #expect(rig.store.assets == [rig.asset])
    }

    @Test(.timeLimit(.minutes(5))) func cancellingTheDownloadStopsWithNoFilesLeft() async throws {
        let rig = try await PhotosRig()
        let task = Task<JobState, any Error> {
            try await rig.runner().run(try rig.job()) { _ in }
        }
        rig.store.beforeInputStep = { step in if step == 2 { task.cancel() } }

        do {
            _ = try await task.value
            Issue.record("expected the run to throw")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(rig.store.saves.isEmpty)
        #expect(rig.workContents.isEmpty)
        #expect(rig.store.assets == [rig.asset])
    }

    @Test(.timeLimit(.minutes(5))) func aVideoDeletedWhileQueuedFailsAsNoLongerInPhotos() async throws {
        let rig = try await PhotosRig()
        let job = try rig.job()
        rig.store.assets = []

        do {
            _ = try await rig.runner().run(job) { _ in }
            Issue.record("expected the run to throw")
        } catch {
            #expect(error.localizedDescription == "No longer in your Photos library")
        }
        #expect(rig.store.inputRequests.isEmpty)
        #expect(rig.workContents.isEmpty)
    }

    @Test(.timeLimit(.minutes(5))) func aSaveThatPhotosRefusesLeavesTheOriginalAndNothingBehind() async throws {
        let rig = try await PhotosRig()
        rig.store.saveError = .unavailable("disk full")

        do {
            _ = try await rig.runner().run(try rig.job(.replace)) { _ in }
            Issue.record("expected the run to throw")
        } catch {
            #expect(
                error as? PhotoSaveError == .saveFailed(PhotoStoreError.unavailable("disk full").localizedDescription))
        }
        #expect(rig.pending.all.isEmpty)
        #expect(rig.store.deletedIDs.isEmpty)
        #expect(rig.store.assets == [rig.asset])
        #expect(rig.workContents.isEmpty)
    }

    @Test(.timeLimit(.minutes(5))) func aNewVideoThatDoesNotVerifyIsRemovedAndTheOriginalIsNeverQueued() async throws {
        let rig = try await PhotosRig()
        rig.store.savedPixelSize = CGSize(width: 1280, height: 720)  // not what was saved

        do {
            _ = try await rig.runner().run(try rig.job(.replace)) { _ in }
            Issue.record("expected the run to throw")
        } catch let error as PhotoSaveError {
            guard case .verifyFailed(_, let cleanup) = error else {
                Issue.record("expected verifyFailed, got \(error)")
                return
            }
            #expect(cleanup == .removed)
            #expect(error.localizedDescription.contains("Your original is untouched"))
        }
        #expect(rig.store.deletedIDs == ["new-1"])
        #expect(!rig.store.deletedIDs.contains(rig.asset.id))
        #expect(rig.pending.all.isEmpty)
        #expect(rig.store.assets == [rig.asset])
        #expect(rig.workContents.isEmpty)
    }

    @Test(.timeLimit(.minutes(5))) func aNewVideoThatCouldNotBeRemovedIsReported() async throws {
        let rig = try await PhotosRig()
        rig.store.savedPixelSize = CGSize(width: 1280, height: 720)
        rig.store.deleteError = CancellationError()  // the user declined the confirmation

        do {
            _ = try await rig.runner().run(try rig.job()) { _ in }
            Issue.record("expected the run to throw")
        } catch let error as PhotoSaveError {
            guard case .verifyFailed(_, let cleanup) = error else {
                Issue.record("expected verifyFailed, got \(error)")
                return
            }
            #expect(cleanup == .declined)
            #expect(error.localizedDescription.contains("remove it in Photos"))
        }
        #expect(rig.pending.all.isEmpty)
    }

    @Test(.timeLimit(.minutes(5))) func anUnshownLossKeepsTheVideoAsIsBeforeAnyEncoding() async throws {
        let rig = try await PhotosRig()
        var inventory = try await MediaInspector().inventory(of: rig.clip)
        inventory.items.append(
            MetadataItem(key: "track.9.kind", category: .video, displayName: "Track 9 kind", value: "auxv/disparity"))
        let settings = ConvertJobSettings(
            preset: .balanced, saveTo: .nextToOriginal, custom: PhotosRig.spec, predictedLost: [],
            photosDestination: .newAsset)
        let size = try #require(RunnerFixture.size(rig.clip))

        let result = try await RunnerFixture.runner().convert(
            source: rig.clip, byteSize: size, inventory: inventory, settings: settings, requireLossShown: true,
            outputFolder: { (rig.directory, {}) }, progress: { _ in })

        guard case .keptAsIs(let reason, _) = result else {
            Issue.record("expected keptAsIs")
            return
        }
        #expect(reason.contains("cinematic depth data"))
        #expect(
            !(try FileManager.default.contentsOfDirectory(atPath: rig.directory.path)).contains { $0.contains("1080p") }
        )
    }

    @Test(.timeLimit(.minutes(5))) func aShownLossIsAllowed() async throws {
        let rig = try await PhotosRig()
        var inventory = try await MediaInspector().inventory(of: rig.clip)
        inventory.items.append(
            MetadataItem(key: "track.9.kind", category: .video, displayName: "Track 9 kind", value: "auxv/disparity"))
        let settings = ConvertJobSettings(
            preset: .balanced, saveTo: .nextToOriginal, custom: PhotosRig.spec,
            predictedLost: ["Cinematic depth data"], photosDestination: .newAsset)
        let size = try #require(RunnerFixture.size(rig.clip))

        let result = try await RunnerFixture.runner().convert(
            source: rig.clip, byteSize: size, inventory: inventory, settings: settings, requireLossShown: true,
            outputFolder: { (rig.directory, {}) }, progress: { _ in })

        guard case .converted(let converted) = result else {
            Issue.record("expected converted, got \(result)")
            return
        }
        try? FileManager.default.removeItem(at: converted.output)
    }

    // MARK: - Queue

    @Test(.timeLimit(.minutes(5))) func aFailedDownloadCanBeRetriedAndThenSucceeds() async throws {
        let rig = try await PhotosRig()
        rig.store.inputError = .downloadFailed("offline")
        let queue = JobQueue(
            store: JobStore(directory: rig.directory),
            runners: [ConvertTool.photosToolID: rig.runner()])
        let job = try rig.job()
        await queue.enqueue([job])
        await Self.waitUntil(queue) { jobs in
            if case .failed = jobs.first?.state { true } else { false }
        }
        guard case .failed(let reason, _) = await queue.jobs[0].state else { return }
        #expect(reason.hasPrefix("Couldn't download from iCloud"))
        #expect(rig.workContents.isEmpty)

        rig.store.inputError = nil
        await queue.retry(job.id)
        await Self.waitUntil(queue) { jobs in
            if case .completed = jobs.first?.state { true } else { false }
        }

        #expect(rig.store.saves.count == 1)
        await queue.shutdown()
    }

    @Test(.timeLimit(.minutes(5))) func twoPhotosJobsShareTheDownloadGateAndWaitInTurn() async throws {
        let rig = try await PhotosRig()
        let secondID = "7A2C9B3D-2E4F-5A6B-8C7D-1F3E5A7B9C2D/L0/001"
        let secondAsset = PhotoAsset(
            id: secondID, creationDate: rig.asset.creationDate, location: rig.asset.location,
            pixelSize: rig.asset.pixelSize, duration: 1.0, isFavorite: false, hasAdjustments: false,
            originalFileName: "IMG_0002.MOV", originalByteSize: rig.asset.originalByteSize,
            isLocallyAvailable: false)
        rig.store.assets = [rig.asset, secondAsset]
        rig.store.originalFiles[secondID] = rig.clip
        rig.store.currentVersionFiles[secondID] = rig.clip

        let (holdFirst, releaseFirst) = AsyncStream.makeStream(of: Void.self)
        let (firstStarted, firstStartedSink) = AsyncStream.makeStream(of: Void.self)
        var firstIterator = firstStarted.makeAsyncIterator()
        let heldOnce = Mutex(false)
        rig.store.beforeInputStep = { step in
            guard step == 1 else { return }
            let shouldHold = heldOnce.withLock { held in
                guard !held else { return false }
                held = true
                return true
            }
            guard shouldHold else { return }
            firstStartedSink.yield()
            for await _ in holdFirst { break }
        }

        let runner = rig.runner()
        let job1 = try rig.job()
        let job2 = try rig.job(id: secondID)
        let log1 = RunLog()

        let task1 = Task { try await log1.run(runner, job1) }
        await firstIterator.next()

        let (secondWaiting, secondWaitingSink) = AsyncStream.makeStream(of: Void.self)
        var waitingIterator = secondWaiting.makeAsyncIterator()
        let task2 = Task {
            try await runner.run(
                job2,
                progress: { _ in },
                phase: { phase in
                    guard let phase else { return }
                    if phase == PhotosConvertRunner.waitingPhase { secondWaitingSink.yield() }
                })
        }
        await waitingIterator.next()
        #expect(rig.store.inputRequests.count == 1)

        releaseFirst.yield()
        let state1 = try await task1.value
        let state2 = try await task2.value
        #expect(completed(state1) != nil)
        #expect(completed(state2) != nil)
        #expect(rig.store.inputRequests.count == 2)
    }

    private static func waitUntil(_ queue: JobQueue, _ predicate: @Sendable ([Job]) -> Bool) async {
        for await jobs in await queue.updates() where predicate(jobs) { return }
    }
}
